import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/folders/data/folder_repository.dart';
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
      deleted_at TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE documents (
      id TEXT PRIMARY KEY,
      folder_id TEXT,
      storage_uri TEXT,
      deleted_at TEXT,
      updated_at TEXT
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

Future<void> _insertFolder(Database db, String id, String name, {String? parentId}) async {
  await db.insert('folders', {
    'id': id,
    'name': name,
    'parent_id': parentId,
    'sort_order': 0,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
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
    await db.insert('documents', {
      'id': 'policy-a',
      'folder_id': 'insurance',
      'storage_uri': 'file:///docs/Insurance/a.pdf',
    });
    await db.insert('documents', {
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
    expect(recycled.every((row) => row['folder_id'] == null), isTrue);
    expect(
      recycled.map((row) => row['storage_uri']).toList(),
      ['file:///docs/Insurance/a.pdf', 'file:///docs/Insurance/Policies/b.pdf'],
    );
    expect(await db.rawQuery('SELECT * FROM history'), hasLength(2));
  });
}
