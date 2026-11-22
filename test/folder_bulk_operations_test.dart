import 'dart:io';

import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _database() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await db.execute('''
    CREATE TABLE folders (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      parent_id TEXT,
      sort_order INTEGER NOT NULL DEFAULT 0,
      storage_uri_or_relative_path TEXT,
      created_at TEXT NOT NULL DEFAULT '2026-01-01T00:00:00Z',
      updated_at TEXT NOT NULL DEFAULT '2026-01-01T00:00:00Z',
      deleted_at TEXT,
      trash_operation_id TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE documents (
      id TEXT PRIMARY KEY,
      name TEXT,
      folder_id TEXT,
      storage_uri TEXT,
      sha256 TEXT,
      size_bytes INTEGER NOT NULL DEFAULT 0,
      deleted_at TEXT,
      updated_at TEXT,
      trash_operation_id TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE history (
      id TEXT PRIMARY KEY,
      document_id TEXT,
      action TEXT NOT NULL,
      details_json TEXT NOT NULL,
      created_at TEXT NOT NULL
    )
  ''');
  return db;
}

Future<void> _insertFolder(Database db, String id, String name,
    {String? parentId}) async {
  await db.insert('folders', {
    'id': id,
    'name': name,
    'parent_id': parentId,
    'sort_order': 0,
    'created_at': '2026-01-01T00:00:00Z',
    'updated_at': '2026-01-01T00:00:00Z',
  });
}

Future<void> _insertDocument(
    Database db, Map<String, Object?> values) async {
  await db.insert('documents', {
    'name': '${values['id']}.pdf',
    'created_at': '2026-01-01T00:00:00Z',
    'updated_at': '2026-01-01T00:00:00Z',
    ...values,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('moving selected parent and child moves only the selected root', () async {
    final db = await _database();
    addTearDown(db.close);
    await _insertFolder(db, 'insurance', 'Insurance');
    await _insertFolder(db, 'motor', 'Motor');
    await _insertFolder(db, 'policies', 'Policies', parentId: 'insurance');
    final repository = FolderRepository(
      database: AppDatabase.forTesting(() async => db),
    );

    await repository.moveManyToParent(['insurance', 'policies'], 'motor');

    final insurance = (await db.query('folders', where: 'id = ?', whereArgs: ['insurance'])).single;
    final policies = (await db.query('folders', where: 'id = ?', whereArgs: ['policies'])).single;
    expect(insurance['parent_id'], 'motor');
    expect(policies['parent_id'], 'insurance');
  });

  test('moving a folder into its own descendant is rejected', () async {
    final db = await _database();
    addTearDown(db.close);
    await _insertFolder(db, 'insurance', 'Insurance');
    await _insertFolder(db, 'policies', 'Policies', parentId: 'insurance');
    final repository = FolderRepository(
      database: AppDatabase.forTesting(() async => db),
    );

    await expectLater(
      repository.moveManyToParent(['insurance'], 'policies'),
      throwsA(isA<StateError>()),
    );
  });

  test('deleting a folder tree sends PDFs to Recycle Bin and keeps file URIs', () async {
    final db = await _database();
    addTearDown(db.close);
    await _insertFolder(db, 'insurance', 'Insurance');
    await _insertFolder(db, 'policies', 'Policies', parentId: 'insurance');
    await _insertDocument(db, {
      'id': 'policy-a',
      'folder_id': 'insurance',
      'storage_uri': 'file:///docs/Insurance/a.pdf',
    });
    await _insertDocument(db, {
      'id': 'policy-b',
      'folder_id': 'policies',
      'storage_uri': 'file:///docs/Insurance/Policies/b.pdf',
    });
    final repository = FolderRepository(
      database: AppDatabase.forTesting(() async => db),
    );

    final moved = await repository.moveManyToRecycleBin(['insurance']);

    expect(moved, 2);
    final deletedFolders = await db.query('folders');
    expect(deletedFolders.every((row) => row['deleted_at'] != null), isTrue);
    final recycled = await db.query('documents', orderBy: 'id');
    expect(recycled.every((row) => row['deleted_at'] != null), isTrue);
    expect(recycled.every((row) => row['folder_id'] != null), isTrue);
    expect(recycled.map((row) => row['folder_id']).toList(),
        ['insurance', 'policies']);
    final operationIds = recycled
        .map((row) => row['trash_operation_id'] as String?)
        .toSet();
    expect(operationIds, hasLength(1));
    expect(operationIds.single, isNotNull);
    expect(deletedFolders.map((row) => row['trash_operation_id']).toSet(),
        operationIds);
    expect(
      recycled.map((row) => row['storage_uri']).toList(),
      ['file:///docs/Insurance/a.pdf', 'file:///docs/Insurance/Policies/b.pdf'],
    );
    expect(await db.rawQuery('SELECT * FROM history'), hasLength(2));
  });

  test('deleting a folder preserves independently recycled PDF folder references', () async {
    final db = await _database();
    addTearDown(db.close);
    await _insertFolder(db, 'insurance', 'Insurance');
    await _insertDocument(db, {
      'id': 'old-trash-entry',
      'folder_id': 'insurance',
      'storage_uri': 'file:///docs/Insurance/old.pdf',
      'deleted_at': '2026-01-02T00:00:00Z',
      'updated_at': '2026-01-02T00:00:00Z',
    });
    final repository = FolderRepository(
      database: AppDatabase.forTesting(() async => db),
    );

    await repository.moveManyToRecycleBin(['insurance']);

    final recycled = (await db.query('documents')).single;
    expect(recycled['deleted_at'], '2026-01-02T00:00:00Z');
    expect(recycled['folder_id'], 'insurance');
    expect(recycled['trash_operation_id'], isNull);
    expect(recycled['storage_uri'], 'file:///docs/Insurance/old.pdf');
  });

  test('folder restore keeps replaced PDF and metadata safely in Trash',
      () async {
    final db = await _database();
    addTearDown(db.close);
    final folder = await Directory.systemTemp.createTemp('docsgrid-folder-hash-');
    addTearDown(() async {
      if (await folder.exists()) await folder.delete(recursive: true);
    });
    final pdf = File('${folder.path}/protected.pdf');
    await pdf.writeAsBytes([37, 80, 68, 70, 45, 49]);
    await _insertFolder(db, 'root', 'Root');
    await db.update('folders', {'storage_uri_or_relative_path': folder.uri.toString()},
        where: 'id = ?', whereArgs: ['root']);
    await _insertDocument(db, {
      'id': 'document', 'folder_id': 'root',
      'storage_uri': pdf.uri.toString(), 'sha256': List.filled(64, '0').join(),
    });
    final repository = FolderRepository(
      database: AppDatabase.forTesting(() async => db),
    );
    await repository.moveManyToRecycleBin(['root']);
    await expectLater(repository.restoreTrashFolderTree('root'),
        throwsA(isA<StateError>()));
    expect((await db.query('documents', where: 'id = ?', whereArgs: ['document']))
        .single['deleted_at'], isNotNull);
    expect((await db.query('folders', where: 'id = ?', whereArgs: ['root']))
        .single['deleted_at'], isNotNull);
    expect(await pdf.exists(), isTrue);
  });

  test('folder trash lists one root and restores its original hierarchy', () async {
    final db = await _database();
    addTearDown(db.close);
    await _insertFolder(db, 'insurance', 'Insurance');
    await _insertFolder(db, 'motor', 'Motor', parentId: 'insurance');
    await _insertFolder(db, 'policies', 'Policies', parentId: 'motor');
    final repository = FolderRepository(
      database: AppDatabase.forTesting(() async => db),
    );

    await repository.moveManyToRecycleBin(['insurance']);
    final roots = await repository.listTrashFolderRoots();
    expect(roots, hasLength(1));
    expect(roots.single['id'], 'insurance');
    expect(roots.single['folder_count'], 3);

    await repository.restoreTrashFolderTree('insurance');
    final restored = await db.query('folders', orderBy: 'id');
    expect(restored.every((row) => row['deleted_at'] == null), isTrue);
    expect(restored.firstWhere((row) => row['id'] == 'motor')['parent_id'], 'insurance');
    expect(restored.firstWhere((row) => row['id'] == 'policies')['parent_id'], 'motor');
    expect(restored.every((row) => row['trash_operation_id'] == null), isTrue);
  });

  test('deleting an empty folder moves it to the Grid Recycle Bin', () async {
    final db = await _database();
    addTearDown(db.close);
    await _insertFolder(db, 'empty', 'Empty');
    final repository = FolderRepository(
      database: AppDatabase.forTesting(() async => db),
    );

    await repository.deleteEmpty('empty');
    final roots = await repository.listTrashFolderRoots();
    expect(roots, hasLength(1));
    expect(roots.single['name'], 'Empty');
    expect(roots.single['pdf_count'], 0);
  });


  test('permanent folder delete detects separately recycled PDFs without SQL syntax error', () async {
    final db = await _database();
    addTearDown(db.close);
    await _insertFolder(db, 'insurance', 'Insurance');
    final repository = FolderRepository(
      database: AppDatabase.forTesting(() async => db),
    );

    await repository.deleteEmpty('insurance');
    await _insertDocument(db, {
      'id': 'separately-recycled',
      'folder_id': 'insurance',
      'storage_uri': 'file:///docs/Insurance/old.pdf',
      'deleted_at': '2026-01-02T00:00:00Z',
      'updated_at': '2026-01-02T00:00:00Z',
    });

    await expectLater(
      repository.permanentlyDeleteTrashFolderTree('insurance'),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('separately recycled PDF'),
      )),
    );
    expect(await db.query('folders'), hasLength(1));
    expect(await db.query('documents'), hasLength(1));

    await db.delete('documents', where: 'id = ?', whereArgs: ['separately-recycled']);
    await repository.permanentlyDeleteTrashFolderTree('insurance');
    expect(await db.query('folders'), isEmpty);
  });

  test('legacy deleted folder rows are grouped into one visible tree', () async {
    final db = await _database();
    addTearDown(db.close);
    final rootDirectory = await Directory.systemTemp.createTemp('docsgrid-legacy-trash-');
    addTearDown(() async {
      if (await rootDirectory.exists()) await rootDirectory.delete(recursive: true);
    });
    final childDirectory = Directory('${rootDirectory.path}/Child');
    await childDirectory.create();
    await _insertFolder(db, 'legacy-root', 'Legacy');
    await _insertFolder(db, 'legacy-child', 'Child', parentId: 'legacy-root');
    await db.update(
      'folders',
      {
        'deleted_at': '2026-10-01T00:00:00Z',
        'storage_uri_or_relative_path': Uri.directory(rootDirectory.path).toString(),
      },
      where: 'id = ?',
      whereArgs: ['legacy-root'],
    );
    await db.update(
      'folders',
      {
        'deleted_at': '2026-10-01T00:00:00Z',
        'storage_uri_or_relative_path': Uri.directory(childDirectory.path).toString(),
      },
      where: 'id = ?',
      whereArgs: ['legacy-child'],
    );
    final repository = FolderRepository(
      database: AppDatabase.forTesting(() async => db),
    );

    final roots = await repository.listTrashFolderRoots();
    expect(roots, hasLength(1));
    expect(roots.single['id'], 'legacy-root');
    expect(roots.single['folder_count'], 2);
    final rows = await db.query('folders', orderBy: 'id');
    expect(rows.every((row) =>
        (row['trash_operation_id'] as String?)?.isNotEmpty == true), isTrue);
    expect(rows.map((row) => row['trash_operation_id']).toSet(), hasLength(1));
  });


  test('an externally missing folder is not reclassified as user trash', () async {
    final db = await _database();
    addTearDown(db.close);
    await _insertFolder(db, 'missing', 'Missing');
    await db.update(
      'folders',
      {'storage_uri_or_relative_path': 'content://provider/missing-folder'},
      where: 'id = ?',
      whereArgs: ['missing'],
    );
    const channel = MethodChannel('docsgrid/storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'NOT_FOUND', message: 'Folder missing');
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final repository = FolderRepository(
      database: AppDatabase.forTesting(() async => db),
    );
    expect(await repository.childrenOf(null), isEmpty);
    final row = (await db.query('folders',
        where: 'id = ?', whereArgs: ['missing'])).single;
    expect(row['deleted_at'], isNull);
    expect(await repository.listTrashFolderRoots(), isEmpty);
  });

  test('real production FK: nested permanent trash deletion removes children first',
      () async {
    final db = await _database();
    addTearDown(db.close);
    final tmp = await Directory.systemTemp.createTemp('docsgrid-dg01-fk-');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final deletedFile = File('${tmp.path}/deleted.pdf');
    final retainedFile = File('${tmp.path}/retained.pdf');
    await deletedFile.writeAsBytes([37, 80, 68, 70, 45, 49]);
    await retainedFile.writeAsBytes([37, 80, 68, 70, 45, 50]);

    await _insertFolder(db, 'parent', 'Parent');
    await _insertFolder(db, 'child', 'Child', parentId: 'parent');
    await _insertFolder(db, 'grandchild', 'Grandchild', parentId: 'child');
    await _insertFolder(db, 'unrelated', 'Unrelated');
    await _insertDocument(db, {
      'id': 'trash-pdf', 'folder_id': 'grandchild',
      'storage_uri': deletedFile.uri.toString(),
    });
    await _insertDocument(db, {
      'id': 'keep-pdf', 'folder_id': 'unrelated',
      'storage_uri': retainedFile.uri.toString(),
    });
    final repository = FolderRepository(
        database: AppDatabase.forTesting(() async => db));

    expect(await repository.moveManyToRecycleBin(['parent']), 1);
    await repository.permanentlyDeleteTrashFolderTree('parent');

    expect(await deletedFile.exists(), isFalse);
    expect(await retainedFile.exists(), isTrue);
    final folders = await db.query('folders', columns: ['id']);
    expect(folders.map((row) => row['id']), ['unrelated']);
    final documents = await db.query('documents', columns: ['id']);
    expect(documents.map((row) => row['id']), ['keep-pdf']);
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    final history = await db.query('history', where: 'action = ?',
        whereArgs: ['folder_tree_permanently_deleted']);
    expect(history, hasLength(1));
  });

  test('missing trash directory fails closed before any PDF is deleted',
      () async {
    final db = await _database();
    addTearDown(db.close);
    final sandbox = await Directory.systemTemp.createTemp('docsgrid-trash-unavailable-');
    addTearDown(() async {
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });
    final safePdf = File('${sandbox.path}/must-survive.pdf');
    await safePdf.writeAsBytes([37, 80, 68, 70, 45, 49]);
    final missing = Directory('${sandbox.path}/removed-by-external-provider');
    await _insertFolder(db, 'unavailable', 'Unavailable');
    await db.update('folders',
      {'storage_uri_or_relative_path': missing.uri.toString()},
      where: 'id = ?', whereArgs: ['unavailable'],
    );
    await _insertDocument(db, {
      'id': 'safe-document', 'folder_id': 'unavailable',
      'storage_uri': safePdf.uri.toString(),
    });
    final repository = FolderRepository(
      database: AppDatabase.forTesting(() async => db),
    );
    await repository.moveManyToRecycleBin(['unavailable']);
    await expectLater(
      repository.permanentlyDeleteTrashFolderTree('unavailable'),
      throwsA(isA<StateError>().having(
        (e) => e.message, 'message', contains('missing or inaccessible'),
      )),
    );
    expect(await safePdf.exists(), isTrue);
    expect(await db.query('documents',
        where: 'id = ?', whereArgs: ['safe-document']), hasLength(1));
    expect(await db.query('folders',
        where: 'id = ?', whereArgs: ['unavailable']), hasLength(1));
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });

  test('independently owned child folder blocks permanent delete before file removal',
      () async {
    final db = await _database();
    addTearDown(db.close);
    final tmp = await Directory.systemTemp.createTemp('docsgrid-dg01-child-');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final pdf = File('${tmp.path}/keep.pdf');
    await pdf.writeAsBytes([37, 80, 68, 70]);

    await _insertFolder(db, 'parent', 'Parent');
    await _insertDocument(db, {
      'id': 'pdf', 'folder_id': 'parent',
      'storage_uri': pdf.uri.toString(),
    });
    final repository = FolderRepository(
        database: AppDatabase.forTesting(() async => db));
    await repository.moveManyToRecycleBin(['parent']);
    // A conflicting live child must not be lost during trash cleanup.
    await _insertFolder(db, 'live-child', 'Live', parentId: 'parent');

    await expectLater(
      repository.permanentlyDeleteTrashFolderTree('parent'),
      throwsA(isA<StateError>().having(
        (error) => error.message, 'message', contains('separately owned child'))),
    );
    expect(await pdf.exists(), isTrue);
    expect(await db.query('folders'), hasLength(2));
    expect(await db.query('documents'), hasLength(1));
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });

}
