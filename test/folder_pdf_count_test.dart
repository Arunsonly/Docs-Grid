import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
  });

  test('folder cards receive direct active PDF counts from the database', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute('''
      CREATE TABLE folders (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        parent_id TEXT,
        sort_order INTEGER NOT NULL DEFAULT 0,
        storage_uri_or_relative_path TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        deleted_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE documents (
        id TEXT PRIMARY KEY,
        folder_id TEXT,
        deleted_at TEXT
      )
    ''');
    await db.insert('folders', {
      'id': 'banking',
      'name': 'Banking',
      'sort_order': 0,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    });
    await db.insert('documents', {'id': 'pdf-1', 'folder_id': 'banking'});
    await db.insert('documents', {'id': 'pdf-2', 'folder_id': 'banking'});
    await db.insert('documents', {
      'id': 'deleted-pdf',
      'folder_id': 'banking',
      'deleted_at': '2026-01-02T00:00:00Z',
    });

    final repository = FolderRepository(
      database: AppDatabase.forTesting(() async => db),
    );
    final folders = await repository.childrenOf(null);

    expect(folders, hasLength(1));
    expect(folders.single.name, 'Banking');
    expect(folders.single.pdfCount, 2);
  });
}
