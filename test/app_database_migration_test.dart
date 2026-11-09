import 'dart:io';

import 'package:docs_grid/core/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    directory = Directory.systemTemp.createTempSync('docsgrid_migrations_');
  });

  tearDown(() {
    directory.deleteSync(recursive: true);
  });

  Future<Database> createV1Fixture(String name, {bool conflictingTags = false}) {
    final path = '${directory.path}/$name.db';
    return databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE folders (
              id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT,
              storage_uri_or_relative_path TEXT, created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL, deleted_at TEXT,
              FOREIGN KEY(parent_id) REFERENCES folders(id) ON DELETE RESTRICT
            )
          ''');
          await db.execute('''
            CREATE TABLE documents (
              id TEXT PRIMARY KEY, name TEXT NOT NULL, original_name TEXT,
              storage_uri TEXT, relative_path TEXT,
              mime_type TEXT NOT NULL DEFAULT 'application/pdf',
              size_bytes INTEGER NOT NULL DEFAULT 0, sha256 TEXT, folder_id TEXT,
              category_id TEXT,
              extracted_text_status TEXT NOT NULL DEFAULT 'pending',
              expiry_date TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
              last_opened_at TEXT, deleted_at TEXT, source TEXT, metadata_json TEXT,
              FOREIGN KEY(folder_id) REFERENCES folders(id) ON DELETE RESTRICT
            )
          ''');
          await db.execute('CREATE INDEX idx_folders_parent ON folders(parent_id, deleted_at)');
          await db.execute('CREATE INDEX idx_documents_folder ON documents(folder_id, deleted_at)');
          await db.execute('''
            CREATE TABLE reminders (
              id TEXT PRIMARY KEY, document_id TEXT, title TEXT NOT NULL, note TEXT,
              remind_at_utc TEXT NOT NULL, timezone_id TEXT NOT NULL,
              recurrence_rule TEXT, recurrence_end_at TEXT, lead_days INTEGER,
              enabled INTEGER NOT NULL DEFAULT 1, status TEXT NOT NULL DEFAULT 'scheduled',
              snoozed_until TEXT, next_fire_at_utc TEXT NOT NULL, notification_id INTEGER,
              created_at TEXT NOT NULL, updated_at TEXT NOT NULL, completed_at TEXT,
              FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE SET NULL
            )
          ''');
          await db.execute('CREATE INDEX idx_reminders_next_fire ON reminders(status, enabled, next_fire_at_utc)');
          await db.execute('CREATE INDEX idx_reminders_document ON reminders(document_id)');
          await db.insert('folders', {
            'id': 'folder-1', 'name': 'Policies', 'created_at': '2024-01-01',
            'updated_at': '2024-01-01',
          });
          await db.insert('documents', {
            'id': 'doc-1', 'name': 'policy.pdf', 'created_at': '2024-01-01',
            'updated_at': '2024-01-01', 'folder_id': 'folder-1',
            'metadata_json': '{"favorite":true}',
          });
          await db.insert('reminders', {
            'id': 'reminder-1', 'document_id': 'doc-1', 'title': 'Renew policy',
            'remind_at_utc': '2025-01-01T09:00:00Z', 'timezone_id': 'UTC',
            'next_fire_at_utc': '2025-01-01T09:00:00Z',
            'created_at': '2024-01-01', 'updated_at': '2024-01-01',
          });
          if (conflictingTags) {
            // Deliberately make the v2 migration fail after it has created
            // categories, proving SQLite rolls the whole upgrade back.
            await db.execute('CREATE TABLE tags (legacy_collision TEXT)');
          }
        },
      ),
    );
  }

  Future<Database> migrateTo(String path, int targetVersion) {
    return databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: targetVersion,
        onUpgrade: (db, oldVersion, newVersion) =>
            AppDatabase.forTesting(() async => db)
                .upgradeForTesting(db, oldVersion, newVersion),
      ),
    );
  }

  group('AppDatabase real SQLite migration fixtures', () {
    test('upgrades a real v1 fixture through v2 and v3 preserving user data', () async {
      final v1 = await createV1Fixture('v1_upgrade');
      final path = v1.path;
      expect(await v1.getVersion(), 1);
      await v1.close();

      final upgraded = await migrateTo(path, 3);
      expect(await upgraded.getVersion(), 3);
      expect(await upgraded.query('folders', where: 'id = ?', whereArgs: ['folder-1']), hasLength(1));
      expect(await upgraded.query('documents', where: 'id = ?', whereArgs: ['doc-1']), hasLength(1));
      expect(await upgraded.query('reminders', where: 'id = ?', whereArgs: ['reminder-1']), hasLength(1));
      expect(await upgraded.query('categories', where: 'name = ?', whereArgs: ['Insurance']), hasLength(1));
      expect(await upgraded.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='document_text_index'"), hasLength(1));
      expect(await upgraded.query('schema_migrations', orderBy: 'version'), hasLength(3));
      expect((await upgraded.query('schema_migrations', orderBy: 'version')).map((row) => row['version']), [1, 2, 3]);
      expect(await upgraded.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      expect(await upgraded.rawQuery('PRAGMA foreign_keys'), isNotEmpty);
      await upgraded.close();
    });

    test('opens a real v2 fixture at v3 without replaying v2 schema', () async {
      final v1 = await createV1Fixture('v2_upgrade');
      final path = v1.path;
      await v1.close();
      final v2 = await migrateTo(path, 2);
      expect(await v2.getVersion(), 2);
      expect(await v2.query('categories'), isNotEmpty);
      expect(await v2.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='document_text_index'"), isEmpty);
      await v2.close();

      final v3 = await migrateTo(path, 3);
      expect(await v3.getVersion(), 3);
      expect(await v3.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='document_text_index'"), hasLength(1));
      expect(await v3.query('categories', where: 'name = ?', whereArgs: ['Insurance']), hasLength(1));
      await v3.close();
    });

    test('v3 to v4 adds indexed favorite flag and preserves legacy favorite metadata', () async {
      final v1 = await createV1Fixture('v3_to_v4');
      final path = v1.path;
      await v1.close();

      final v3 = await migrateTo(path, 3);
      expect(await v3.getVersion(), 3);
      await v3.close();

      final v4 = await migrateTo(path, 4);
      expect(await v4.getVersion(), 4);
      final document = (await v4.query('documents', where: 'id = ?', whereArgs: ['doc-1'])).single;
      expect(document['is_favorite'], 1);
      final indexes = await v4.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_documents_active_%'",
      );
      expect(indexes.map((row) => row['name']), containsAll([
        'idx_documents_active_recent',
        'idx_documents_active_favorite_recent',
        'idx_documents_active_folder_name',
        'idx_documents_active_category',
      ]));
      expect((await v4.query('schema_migrations', orderBy: 'version')).map((row) => row['version']), [1, 2, 3, 4]);
      expect(await v4.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      await v4.close();
    });

    test('v4 to v5 invalidates cached summary through insert update and delete triggers', () async {
      final fixture = await createV1Fixture('v4_to_v5');
      final path = fixture.path;
      await fixture.close();
      final v4 = await migrateTo(path, 4);
      await v4.close();
      final v5 = await migrateTo(path, 5);
      expect(await v5.getVersion(), 5);
      final state = await v5.query('document_summary_state', where: 'id = ?', whereArgs: [1]);
      expect(state, hasLength(1));
      final triggers = await v5.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'documents_summary_after_%'",
      );
      expect(triggers.map((row) => row['name']), containsAll([
        'documents_summary_after_insert',
        'documents_summary_after_update',
        'documents_summary_after_delete',
      ]));
      final before = state.single['revision'] as int;
      await v5.insert('documents', {
        'id': 'doc-2', 'name': 'second.pdf', 'created_at': '2024-01-02',
        'updated_at': '2024-01-02', 'size_bytes': 512,
      });
      final afterInsert = (await v5.query('document_summary_state')).single['revision'] as int;
      expect(afterInsert, before + 1);
      await v5.update('documents', {'deleted_at': '2024-01-03'}, where: 'id = ?', whereArgs: ['doc-2']);
      final afterUpdate = (await v5.query('document_summary_state')).single['revision'] as int;
      expect(afterUpdate, afterInsert + 1);
      await v5.delete('documents', where: 'id = ?', whereArgs: ['doc-2']);
      final afterDelete = (await v5.query('document_summary_state')).single['revision'] as int;
      expect(afterDelete, afterUpdate + 1);
      expect((await v5.query('schema_migrations', orderBy: 'version')).map((row) => row['version']), [1, 2, 3, 4, 5]);
      await v5.close();
    });

    test('v5 to v6 installs optional trigram search accelerator without changing migration safety', () async {
      final fixture = await createV1Fixture('v5_to_v6');
      final path = fixture.path;
      await fixture.close();
      final v5 = await migrateTo(path, 5);
      await v5.close();
      final v6 = await migrateTo(path, 6);
      expect(await v6.getVersion(), 6);
      final triggers = await v6.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'documents_name_fts_after_%'",
      );
      if (triggers.isNotEmpty) {
        expect(triggers.map((row) => row['name']), containsAll([
          'documents_name_fts_after_insert',
          'documents_name_fts_after_update',
          'documents_name_fts_after_delete',
        ]));
      }
      expect((await v6.query('schema_migrations', orderBy: 'version')).map((row) => row['version']), [1, 2, 3, 4, 5, 6]);
      expect(await v6.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      await v6.close();
    });

    test('refuses downgrade and leaves the v2 database and records intact', () async {
      final v1 = await createV1Fixture('downgrade');
      final path = v1.path;
      await v1.close();
      final v2 = await migrateTo(path, 2);
      await v2.close();

      await expectLater(
        databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 1,
            onDowngrade: (db, oldVersion, newVersion) async {
              throw StateError('Database downgrade is not supported');
            },
          ),
        ),
        throwsA(isA<StateError>()),
      );

      final stillV2 = await databaseFactoryFfi.openDatabase(path);
      expect(await stillV2.getVersion(), 2);
      expect(await stillV2.query('documents', where: 'id = ?', whereArgs: ['doc-1']), hasLength(1));
      expect(await stillV2.query('categories', where: 'name = ?', whereArgs: ['Insurance']), hasLength(1));
      await stillV2.close();
    });

    test('rolls back partially applied v1 to v2 migration on SQLite error', () async {
      final fixture = await createV1Fixture('rollback', conflictingTags: true);
      final path = fixture.path;
      await fixture.close();

      await expectLater(migrateTo(path, 3), throwsA(isA<DatabaseException>()));

      final unchanged = await databaseFactoryFfi.openDatabase(path);
      expect(await unchanged.getVersion(), 1);
      expect(await unchanged.query('documents', where: 'id = ?', whereArgs: ['doc-1']), hasLength(1));
      final categories = await unchanged.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='categories'",
      );
      expect(categories, isEmpty);
      await unchanged.close();
    });
  });
}
