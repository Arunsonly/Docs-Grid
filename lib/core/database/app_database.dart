import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._({this._opener});
  @visibleForTesting
  AppDatabase.forTesting(Future<Database> Function() opener) : this._(opener: opener);

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
      version: 3,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE folders (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            parent_id TEXT,
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
      },
      onUpgrade: upgradeForTesting,
    );
  }

  @visibleForTesting
  Future<void> upgradeForTesting(Database db, int oldVersion, int newVersion) async {
        // Databases created by the original v1 app predate schema_migrations.
        // Create the tracking table before recording the first upgrade so an
        // existing user's database can migrate without a missing-table crash.
        await db.execute('''
          CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL
          )
        ''');
        if (oldVersion < 2) {
          await _createV2Tables(db);
          await db.insert('schema_migrations', {
            'version': 2,
            'applied_at': DateTime.now().toUtc().toIso8601String(),
          });
        }
        if (oldVersion < 3) {
          await _createV3Tables(db);
          await db.insert('schema_migrations', {
            'version': 3,
            'applied_at': DateTime.now().toUtc().toIso8601String(),
          });
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
