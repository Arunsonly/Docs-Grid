import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _setupDatabase() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await db.execute('''
    CREATE TABLE folders (
      id TEXT PRIMARY KEY,
      parent_id TEXT,
      deleted_at TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE documents (
      id TEXT PRIMARY KEY,
      folder_id TEXT,
      size_bytes INTEGER,
      deleted_at TEXT
    )
  ''');
  for (final folder in [
    {'id': 'a', 'parent_id': null, 'deleted_at': null},
    {'id': 'a1', 'parent_id': 'a', 'deleted_at': null},
    {'id': 'a2', 'parent_id': 'a1', 'deleted_at': null},
    {'id': 'b', 'parent_id': null, 'deleted_at': null},
    {'id': 'b1', 'parent_id': 'b', 'deleted_at': null},
    {'id': 'deleted', 'parent_id': 'a', 'deleted_at': '2026-01-01'},
  ]) {
    await db.insert('folders', folder);
  }
  for (final document in [
    {'id': 'a-pdf', 'folder_id': 'a', 'size_bytes': 1024, 'deleted_at': null},
    {'id': 'a1-pdf', 'folder_id': 'a1', 'size_bytes': 2048, 'deleted_at': null},
    {'id': 'a2-pdf', 'folder_id': 'a2', 'size_bytes': 4096, 'deleted_at': null},
    {'id': 'b1-pdf', 'folder_id': 'b1', 'size_bytes': 512, 'deleted_at': null},
    {'id': 'trashed-pdf', 'folder_id': 'a', 'size_bytes': 99999, 'deleted_at': '2026-01-01'},
    {'id': 'deleted-folder-pdf', 'folder_id': 'deleted', 'size_bytes': 88888, 'deleted_at': null},
  ]) {
    await db.insert('documents', document);
  }
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test('selected folders show all nested folders, PDFs and summed sizes', () async {
    final db = await _setupDatabase();
    addTearDown(db.close);
    final repository = FolderRepository(
      database: AppDatabase.forTesting(() async => db),
    );

    final details = await repository.selectionDetails({'a', 'b'});
    expect(details.selectedFolderCount, 2);
    expect(details.nestedFolderCount, 3); // a1, a2, b1
    expect(details.pdfCount, 4);
    expect(details.totalPdfSizeBytes, 1024 + 2048 + 4096 + 512);
  });

  test('overlapping parent and selected child are counted once', () async {
    final db = await _setupDatabase();
    addTearDown(db.close);
    final details = await FolderRepository(
      database: AppDatabase.forTesting(() async => db),
    ).selectionDetails({'a', 'a1'});
    expect(details.selectedFolderCount, 2);
    expect(details.nestedFolderCount, 1); // a2, with no double counting
    expect(details.pdfCount, 3);
    expect(details.totalPdfSizeBytes, 1024 + 2048 + 4096);
  });

  test('read-only details do not modify any folder or document', () async {
    final db = await _setupDatabase();
    addTearDown(db.close);
    final repository = FolderRepository(
      database: AppDatabase.forTesting(() async => db),
    );
    final beforeFolders = await db.query('folders', orderBy: 'id');
    final beforePdfs = await db.query('documents', orderBy: 'id');
    final empty = await repository.selectionDetails({});
    expect(empty.selectedFolderCount, 0);
    expect(empty.pdfCount, 0);
    await repository.selectionDetails({'a', 'b'});
    expect(await db.query('folders', orderBy: 'id'), beforeFolders);
    expect(await db.query('documents', orderBy: 'id'), beforePdfs);
  });
}
