import 'dart:async';
import 'dart:io';

import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/core/storage/durable_file_operations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<Database> openDb() =>
      AppDatabase.instance.openProductionSchemaForTesting(inMemoryDatabasePath);

  test('v12 journal is present in the real production SQLite schema', () async {
    final db = await openDb();
    addTearDown(db.close);
    expect(await db.getVersion(), AppDatabase.schemaVersion);
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    final schema = await db.rawQuery("PRAGMA table_info(file_operation_journal)");
    expect(schema.map((row) => row['name']), contains('resource_key'));
    expect(schema.map((row) => row['name']), contains('owner_id'));
  });

  test('incomplete physical delete blocks conflicting folder restore', () async {
    final db = await openDb();
    addTearDown(db.close);
    await expectLater(
      DurableFileOperations.run<void>(
        db: db, resourceKey: 'trash-tree:folder-1',
        kind: 'delete-folder-tree',
        action: (lease) async {
          await lease.phase('deleting-pdf-bytes');
          throw StateError('simulated write failure');
        },
      ),
      throwsStateError,
    );
    final incomplete = await DurableFileOperations.incomplete(db);
    expect(incomplete, hasLength(1));
    expect(incomplete.single['phase'], 'deleting-pdf-bytes');
    await expectLater(
      DurableFileOperations.run<void>(
        db: db, resourceKey: 'trash-tree:folder-1',
        kind: 'restore-folder-tree',
        action: (_) async {},
      ),
      throwsStateError,
    );
    // The same operation may safely revalidate and resume its own journal.
    await DurableFileOperations.run<void>(
      db: db, resourceKey: 'trash-tree:folder-1',
      kind: 'delete-folder-tree',
      action: (lease) async => lease.phase('metadata-committed'),
    );
    expect(await DurableFileOperations.incomplete(db), isEmpty);
  });

  test('rejected preflight does not poison a folder for recovery', () async {
    final db = await openDb();
    addTearDown(db.close);
    await expectLater(
      DurableFileOperations.run<void>(
        db: db, resourceKey: 'trash-tree:parent',
        kind: 'restore-pdf', action: (_) async {
          throw StateError('Restore the containing folder first');
        },
      ),
      throwsStateError,
    );
    expect(await DurableFileOperations.incomplete(db), isEmpty);
    await DurableFileOperations.run<void>(
      db: db, resourceKey: 'trash-tree:parent',
      kind: 'restore-folder-tree', action: (_) async {},
    );
    expect(await DurableFileOperations.incomplete(db), isEmpty);
  });

  test('concurrent work with same resource cannot enter twice', () async {
    final db = await openDb();
    addTearDown(db.close);
    final entered = Completer<void>();
    final resume = Completer<void>();
    final first = DurableFileOperations.run<void>(
      db: db, resourceKey: 'document:one', kind: 'delete-pdf',
      action: (lease) async {
        entered.complete();
        await resume.future;
      },
    );
    await entered.future;
    try {
      await expectLater(
        DurableFileOperations.run<void>(
          db: db, resourceKey: 'document:one', kind: 'restore-pdf',
          action: (_) async {},
        ),
        throwsStateError,
      );
    } finally {
      resume.complete();
      await first;
    }
    expect(await DurableFileOperations.incomplete(db), isEmpty);
  });

  test('restart reconciles a completed physical delete by database state only',
      () async {
    final directory = await Directory.systemTemp.createTemp('docsgrid-operation-recovery-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final path = '${directory.path}/operations.db';
    final db = await AppDatabase.instance.openProductionSchemaForTesting(path);
    await db.insert('file_operation_journal', {
      'resource_key': 'document:already-removed',
      'operation_id': 'completed-delete',
      'kind': 'delete-pdf',
      'owner_id': 'previous-process',
      'state': 'interrupted',
      'phase': 'deleting-pdf-record',
      'created_at': '2026-11-18T00:00:00Z',
      'updated_at': '2026-11-18T00:00:00Z',
    });
    await db.insert('file_operation_journal', {
      'resource_key': 'trash-tree:still-pending',
      'operation_id': 'incomplete-tree-delete',
      'kind': 'delete-folder-tree',
      'owner_id': 'previous-process',
      'state': 'interrupted',
      'phase': 'deleting-pdf-bytes',
      'created_at': '2026-11-18T00:00:00Z',
      'updated_at': '2026-11-18T00:00:00Z',
    });
    await db.close();
    final reopened = await AppDatabase.instance.openProductionSchemaForTesting(path);
    addTearDown(reopened.close);
    final done = await reopened.query('file_operation_journal',
      where: 'operation_id = ?', whereArgs: ['completed-delete']);
    expect(done.single['state'], 'completed');
    expect(done.single['phase'], 'reconciled-after-restart');
    final pending = await DurableFileOperations.incomplete(reopened);
    expect(pending, hasLength(1));
    expect(pending.single['resource_key'], 'trash-tree:still-pending');
  });

  test('v11 development DB upgrades to v12 without deleting documents', () async {
    final directory = await Directory.systemTemp.createTemp('docsgrid-v12-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final path = '${directory.path}/docs_grid.db';
    final initial = await AppDatabase.instance.openProductionSchemaForTesting(path);
    await initial.insert('documents', {
      'id': 'preserved-pdf', 'name': 'Preserved',
      'storage_uri': 'missing://sample', 'mime_type': 'application/pdf',
      'size_bytes': 1, 'created_at': '2026-11-18T00:00:00Z',
      'updated_at': '2026-11-18T00:00:00Z',
    });
    // Construct a v11-representative database using production schema
    // callbacks, not a weaker hand-built collection of tables.
    await initial.execute('DROP TABLE file_operation_journal');
    await initial.execute('DROP INDEX IF EXISTS idx_file_operation_journal_state');
    await initial.delete('schema_migrations', where: 'version = ?', whereArgs: [12]);
    await initial.setVersion(11);
    await initial.close();
    final upgraded = await AppDatabase.instance.openProductionSchemaForTesting(path);
    addTearDown(upgraded.close);
    expect(await upgraded.getVersion(), 12);
    expect(await upgraded.query('documents', where: 'id = ?', whereArgs: ['preserved-pdf']),
        hasLength(1));
    expect(await upgraded.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    expect(await upgraded.rawQuery("PRAGMA table_info(file_operation_journal)"), isNotEmpty);
  });
}
