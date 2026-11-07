import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    final directory = await getApplicationDocumentsDirectory();
    final dbPath = p.join(directory.path, 'docs_grid.db');
    _database = await openDatabase(
      dbPath,
      version: 1,
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
        await db.insert('schema_migrations', {
          'version': 1,
          'applied_at': DateTime.now().toUtc().toIso8601String(),
        });
      },
    );
    return _database!;
  }
}
