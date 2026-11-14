import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._({this._opener});
  @visibleForTesting
  AppDatabase.forTesting(Future<Database> Function() opener) : this._(opener: opener);

  static const int schemaVersion = 11;
  static final AppDatabase instance = AppDatabase._();
  final Future<Database> Function()? _opener;

  Database? _database;
  Future<Database>? _openingDatabase;

  Future<Database> get database async {
    final current = _database;
    if (current != null) return current;

    // Share the first-open Future so simultaneous first repository calls do
    // not race to open and initialize the same SQLite database.
    final opening = _openingDatabase;
    if (opening != null) return opening;

    final future = _opener?.call() ?? _openDatabase();
    _openingDatabase = future;
    try {
      final opened = await future;
      _database = opened;
      return opened;
    } catch (_) {
      _openingDatabase = null;
      rethrow;
    }
  }

  Future<Database> _openDatabase() async {
    final directory = await getApplicationDocumentsDirectory();
    final dbPath = p.join(directory.path, 'docs_grid.db');
    return openDatabase(
      dbPath,
      version: schemaVersion,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE folders (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            parent_id TEXT,
            sort_order INTEGER NOT NULL DEFAULT 0,
            storage_uri_or_relative_path TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            deleted_at TEXT,
            FOREIGN KEY(parent_id) REFERENCES folders(id) ON DELETE RESTRICT
          )
        ''');
        await db.execute('CREATE INDEX idx_folders_parent ON folders(parent_id, deleted_at)');
        await db.execute('''
          CREATE TABLE documents (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            original_name TEXT,
            storage_uri TEXT,
            relative_path TEXT,
            mime_type TEXT NOT NULL DEFAULT 'application/pdf',
            size_bytes INTEGER NOT NULL DEFAULT 0,
            sha256 TEXT,
            folder_id TEXT,
            category_id TEXT,
            extracted_text_status TEXT NOT NULL DEFAULT 'pending',
            expiry_date TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            last_opened_at TEXT,
            deleted_at TEXT,
            source TEXT,
            metadata_json TEXT,
            FOREIGN KEY(folder_id) REFERENCES folders(id) ON DELETE RESTRICT
          )
        ''');
        await db.execute('CREATE INDEX idx_documents_folder ON documents(folder_id, deleted_at)');
        await db.execute('''
          CREATE TABLE reminders (
            id TEXT PRIMARY KEY,
            document_id TEXT,
            title TEXT NOT NULL,
            note TEXT,
            remind_at_utc TEXT NOT NULL,
            timezone_id TEXT NOT NULL,
            recurrence_rule TEXT,
            recurrence_end_at TEXT,
            lead_days INTEGER,
            enabled INTEGER NOT NULL DEFAULT 1,
            status TEXT NOT NULL DEFAULT 'scheduled',
            snoozed_until TEXT,
            next_fire_at_utc TEXT NOT NULL,
            notification_id INTEGER,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            completed_at TEXT,
            FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE SET NULL
          )
        ''');
        await db.execute('CREATE INDEX idx_reminders_next_fire ON reminders(status, enabled, next_fire_at_utc)');
        await db.execute('CREATE INDEX idx_reminders_document ON reminders(document_id)');
        await db.execute('''
          CREATE TABLE schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL
          )
        ''');
        await _createV2Tables(db);
        await _createV3Tables(db);
        await _createV4PerformanceSchema(db);
        await _createV5SummaryInvalidation(db);
        await _createV6NameSearchIndex(db);
        await _createV7FolderOrder(db);
        await _createV8SmartCollections(db);
        await _createV9SmartCollectionFilters(db);
        await _createV10PortableSnapshotState(db);
        await _createV11TrashState(db);
        await db.insert('schema_migrations', {
          'version': 1,
          'applied_at': DateTime.now().toUtc().toIso8601String(),
        });
        await db.insert('schema_migrations', {
          'version': 2,
          'applied_at': DateTime.now().toUtc().toIso8601String(),
        });
        await db.insert('schema_migrations', {
          'version': 3,
          'applied_at': DateTime.now().toUtc().toIso8601String(),
        });
        await db.insert('schema_migrations', {
          'version': 4,
          'applied_at': DateTime.now().toUtc().toIso8601String(),
        });
        await db.insert('schema_migrations', {
          'version': 5,
          'applied_at': DateTime.now().toUtc().toIso8601String(),
        });
        await db.insert('schema_migrations', {
          'version': 6,
          'applied_at': DateTime.now().toUtc().toIso8601String(),
        });
        await db.insert('schema_migrations', {
          'version': 7,
          'applied_at': DateTime.now().toUtc().toIso8601String(),
        });
        await db.insert('schema_migrations', {
          'version': 8,
          'applied_at': DateTime.now().toUtc().toIso8601String(),
        });
        await db.insert('schema_migrations', {
          'version': 9,
          'applied_at': DateTime.now().toUtc().toIso8601String(),
        });
        await db.insert('schema_migrations', {
          'version': 10,
          'applied_at': DateTime.now().toUtc().toIso8601String(),
        });
        await db.insert('schema_migrations', {
          'version': 11,
          'applied_at': DateTime.now().toUtc().toIso8601String(),
        });
      },
      onUpgrade: upgradeForTesting,
      onDowngrade: (db, oldVersion, newVersion) async {
        throw StateError(
          'Database downgrade from $oldVersion to $newVersion is not supported',
        );
      },
    );
  }

  @visibleForTesting
  Future<void> upgradeForTesting(Database db, int oldVersion, int newVersion) async {
    if (newVersion <= oldVersion) return;
    if (oldVersion < 1 || newVersion > schemaVersion) {
      throw StateError('Unsupported database migration: $oldVersion -> $newVersion');
    }

    // Legacy v1 databases predate the migration ledger. Create it inside
    // SQLite's onUpgrade transaction so a failed migration leaves no partial
    // schema or ledger entries behind.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL
      )
    ''');
    final applied = DateTime.now().toUtc().toIso8601String();
    if (oldVersion == 1) {
      await db.insert('schema_migrations', {'version': 1, 'applied_at': applied},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    if (oldVersion < 2 && newVersion >= 2) {
      await _createV2Tables(db);
      await db.insert('schema_migrations', {'version': 2, 'applied_at': applied},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    if (oldVersion < 3 && newVersion >= 3) {
      await _createV3Tables(db);
      await db.insert('schema_migrations', {'version': 3, 'applied_at': applied},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    if (oldVersion < 4 && newVersion >= 4) {
      await _createV4PerformanceSchema(db);
      await db.insert('schema_migrations', {'version': 4, 'applied_at': applied},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    if (oldVersion < 5 && newVersion >= 5) {
      await _createV5SummaryInvalidation(db);
      await db.insert('schema_migrations', {'version': 5, 'applied_at': applied},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    if (oldVersion < 6 && newVersion >= 6) {
      await _createV6NameSearchIndex(db);
      await db.insert('schema_migrations', {'version': 6, 'applied_at': applied},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    if (oldVersion < 7 && newVersion >= 7) {
      await _createV7FolderOrder(db);
      await db.insert('schema_migrations', {'version': 7, 'applied_at': applied},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    if (oldVersion < 8 && newVersion >= 8) {
      await _createV8SmartCollections(db);
      await db.insert('schema_migrations', {'version': 8, 'applied_at': applied},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    if (oldVersion < 9 && newVersion >= 9) {
      await _createV9SmartCollectionFilters(db);
      await db.insert('schema_migrations', {'version': 9, 'applied_at': applied},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    if (oldVersion < 10 && newVersion >= 10) {
      await _createV10PortableSnapshotState(db);
      await db.insert('schema_migrations', {'version': 10, 'applied_at': applied},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    if (oldVersion < 11 && newVersion >= 11) {
      await _createV11TrashState(db);
      await db.insert('schema_migrations', {'version': 11, 'applied_at': applied},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<void> _createV4PerformanceSchema(DatabaseExecutor db) async {
    final columns = await db.rawQuery('PRAGMA table_info(documents)');
    final hasFavorite = columns.any((column) => column['name'] == 'is_favorite');
    if (!hasFavorite) {
      await db.execute(
        'ALTER TABLE documents ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0',
      );
      // Backfill legacy JSON metadata in Dart: SQLite JSON1 is not available
      // on every Android/iOS SQLite build supported by this application.
      final rows = await db.query(
        'documents',
        columns: ['id', 'metadata_json'],
        where: 'metadata_json IS NOT NULL AND metadata_json != ?',
        whereArgs: [''],
      );
      final batch = db.batch();
      for (final row in rows) {
        var favorite = false;
        try {
          final decoded = jsonDecode(row['metadata_json'] as String);
          favorite = decoded is Map && decoded['favorite'] == true;
        } catch (_) {
          // Invalid optional metadata defaults to not-favorite; document data
          // itself remains untouched and readable.
        }
        if (favorite) {
          batch.update(
            'documents',
            {'is_favorite': 1},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        }
      }
      await batch.commit(noResult: true);
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_documents_active_recent ON documents(deleted_at, last_opened_at DESC, name COLLATE NOCASE, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_documents_active_favorite_recent ON documents(deleted_at, is_favorite, last_opened_at DESC, name COLLATE NOCASE, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_documents_active_folder_name ON documents(deleted_at, folder_id, name COLLATE NOCASE, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_documents_active_category ON documents(deleted_at, category_id)',
    );
  }

  Future<void> _createV5SummaryInvalidation(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS document_summary_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        revision INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.insert(
      'document_summary_state',
      {'id': 1, 'revision': 0},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    // Triggers cover every writer: repository methods, imports, restores,
    // backup recovery, and future code paths. The cache is valid only while
    // this monotonic revision remains unchanged.
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS documents_summary_after_insert
      AFTER INSERT ON documents BEGIN
        UPDATE document_summary_state SET revision = revision + 1 WHERE id = 1;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS documents_summary_after_update
      AFTER UPDATE ON documents BEGIN
        UPDATE document_summary_state SET revision = revision + 1 WHERE id = 1;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS documents_summary_after_delete
      AFTER DELETE ON documents BEGIN
        UPDATE document_summary_state SET revision = revision + 1 WHERE id = 1;
      END
    ''');
  }

  Future<void> _createV8SmartCollections(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS smart_collections (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL COLLATE NOCASE UNIQUE,
        query_text TEXT NOT NULL DEFAULT '',
        favorites_only INTEGER NOT NULL DEFAULT 0,
        recent_only INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_smart_collections_name ON smart_collections(name COLLATE NOCASE)',
    );
  }

  /// Tracks durable user-data mutations independently from UI state.
  /// SQLite triggers make this reliable even when a writer bypasses a repository.
  Future<void> _createV11TrashState(DatabaseExecutor db) async {
    // One id groups a deleted folder tree and only the PDFs deliberately
    // moved with that tree. Existing independently trashed PDFs remain separate.
    for (final table in ['folders', 'documents']) {
      final columns = await db.rawQuery('PRAGMA table_info($table)');
      if (!columns.any((column) => column['name'] == 'trash_operation_id')) {
        await db.execute('ALTER TABLE $table ADD COLUMN trash_operation_id TEXT');
      }
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_folders_trash_operation '
      'ON folders(trash_operation_id, deleted_at, parent_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_documents_trash_operation '
      'ON documents(trash_operation_id, deleted_at, folder_id)',
    );

    // Legacy deleted-folder records are reconciled by FolderRepository only
    // after verifying that the physical directory still exists and is readable.
    // Database migration alone must not classify missing/revoked folders as trash.
  }

  Future<void> _createV10PortableSnapshotState(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS portable_snapshot_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        revision INTEGER NOT NULL DEFAULT 1,
        last_snapshot_revision INTEGER NOT NULL DEFAULT 0,
        last_snapshot_at TEXT,
        last_snapshot_name TEXT
      )
    ''');
    await db.insert(
      'portable_snapshot_state',
      {'id': 1, 'revision': 1, 'last_snapshot_revision': 0},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    const durableTables = <String>[
      'folders',
      'documents',
      'categories',
      'tags',
      'document_tags',
      'reminders',
      'history',
      'settings',
      'document_text_index',
      'smart_collections',
    ];
    for (final table in durableTables) {
      for (final operation in const ['INSERT', 'UPDATE', 'DELETE']) {
        final trigger = 'portable_snapshot_${table}_${operation.toLowerCase()}';
        await db.execute('''
          CREATE TRIGGER IF NOT EXISTS $trigger
          AFTER $operation ON $table
          BEGIN
            UPDATE portable_snapshot_state
            SET revision = revision + 1
            WHERE id = 1;
          END
        ''');
      }
    }
  }

  /// Returns whether a portable metadata snapshot is older than the live DB.
  Future<bool> isPortableSnapshotDirty() async {
    final db = await database;
    final rows = await db.query(
      'portable_snapshot_state',
      columns: ['revision', 'last_snapshot_revision'],
      where: 'id = 1',
      limit: 1,
    );
    if (rows.isEmpty) return true;
    return (rows.single['revision'] as int) !=
        (rows.single['last_snapshot_revision'] as int);
  }

  Future<int> portableSnapshotRevision() async {
    final db = await database;
    final rows = await db.query(
      'portable_snapshot_state',
      columns: ['revision'],
      where: 'id = 1',
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Portable snapshot state is not initialized.');
    return rows.single['revision'] as int;
  }

  /// Marks only the exact captured revision clean. Mutations which happen while
  /// an export is running remain dirty and cause another snapshot pass.
  Future<bool> markPortableSnapshotClean({
    required int capturedRevision,
    required String snapshotName,
  }) async {
    final db = await database;
    final count = await db.update(
      'portable_snapshot_state',
      {
        'last_snapshot_revision': capturedRevision,
        'last_snapshot_at': DateTime.now().toUtc().toIso8601String(),
        'last_snapshot_name': snapshotName,
      },
      where: 'id = 1 AND revision = ?',
      whereArgs: [capturedRevision],
    );
    return count == 1;
  }

  Future<void> _createV9SmartCollectionFilters(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS smart_collections (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL COLLATE NOCASE UNIQUE,
        query_text TEXT NOT NULL DEFAULT '',
        favorites_only INTEGER NOT NULL DEFAULT 0,
        recent_only INTEGER NOT NULL DEFAULT 0,
        category_id TEXT,
        tag_ids_json TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    final columns = await db.rawQuery('PRAGMA table_info(smart_collections)');
    final names = columns.map((row) => row['name']).toSet();
    if (!names.contains('category_id')) await db.execute('ALTER TABLE smart_collections ADD COLUMN category_id TEXT');
    if (!names.contains('tag_ids_json')) await db.execute("ALTER TABLE smart_collections ADD COLUMN tag_ids_json TEXT NOT NULL DEFAULT '[]'");
    await db.execute('CREATE INDEX IF NOT EXISTS idx_smart_collections_category ON smart_collections(category_id)');
  }

  Future<void> _createV7FolderOrder(DatabaseExecutor db) async {
    final columns = await db.rawQuery('PRAGMA table_info(folders)');
    final hasSortOrder = columns.any((column) => column['name'] == 'sort_order');
    if (!hasSortOrder) {
      await db.execute(
        'ALTER TABLE folders ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0',
      );
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_folders_parent_order ON folders(parent_id, deleted_at, sort_order, name COLLATE NOCASE)',
    );
  }

  Future<void> _createV6NameSearchIndex(DatabaseExecutor db) async {
    try {
      await db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS documents_name_fts
        USING fts5(name, content='documents', content_rowid='rowid',
                   tokenize='trigram')
      ''');
      await db.execute("INSERT INTO documents_name_fts(documents_name_fts) VALUES('rebuild')");
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS documents_name_fts_after_insert
        AFTER INSERT ON documents BEGIN
          INSERT INTO documents_name_fts(rowid, name) VALUES (new.rowid, new.name);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS documents_name_fts_after_delete
        AFTER DELETE ON documents BEGIN
          INSERT INTO documents_name_fts(documents_name_fts, rowid, name)
          VALUES ('delete', old.rowid, old.name);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS documents_name_fts_after_update
        AFTER UPDATE OF name ON documents BEGIN
          INSERT INTO documents_name_fts(documents_name_fts, rowid, name)
          VALUES ('delete', old.rowid, old.name);
          INSERT INTO documents_name_fts(rowid, name) VALUES (new.rowid, new.name);
        END
      ''');
    } catch (_) {
      for (final trigger in [
        'documents_name_fts_after_insert',
        'documents_name_fts_after_update',
        'documents_name_fts_after_delete',
      ]) {
        try { await db.execute('DROP TRIGGER IF EXISTS $trigger'); } catch (_) {}
      }
      try { await db.execute('DROP TABLE IF EXISTS documents_name_fts'); } catch (_) {}
    }
  }

  Future<void> _createV3Tables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS document_text_index (
        document_id TEXT PRIMARY KEY,
        extracted_text TEXT NOT NULL DEFAULT '',
        indexed_at TEXT NOT NULL,
        page_count INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_documents_sha256 ON documents(sha256)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_documents_expiry ON documents(expiry_date, deleted_at)');
  }

  Future<void> _createV2Tables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS categories (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL COLLATE NOCASE UNIQUE,
        icon_key TEXT,
        color_key TEXT,
        is_builtin INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tags (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL COLLATE NOCASE UNIQUE,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS document_tags (
        document_id TEXT NOT NULL,
        tag_id TEXT NOT NULL,
        PRIMARY KEY(document_id, tag_id),
        FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE,
        FOREIGN KEY(tag_id) REFERENCES tags(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS history (
        id TEXT PRIMARY KEY,
        document_id TEXT,
        action TEXT NOT NULL,
        details_json TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE SET NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value_json TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_categories_name ON categories(name COLLATE NOCASE)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_tags_name ON tags(name COLLATE NOCASE)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_history_document ON history(document_id, created_at)');
    const defaults = ['Identity', 'Insurance', 'Finance', 'Medical', 'Property', 'Vehicle', 'Education', 'Other'];
    for (final name in defaults) {
      await db.insert('categories', {
        'id': name.toLowerCase(),
        'name': name,
        'is_builtin': 1,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }
}
