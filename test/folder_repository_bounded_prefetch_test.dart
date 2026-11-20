import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late FolderRepository repository;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE folders (
        id TEXT PRIMARY KEY, name TEXT NOT NULL,
        parent_id TEXT, storage_uri_or_relative_path TEXT,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        deleted_at TEXT, sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('CREATE TABLE documents (id TEXT, folder_id TEXT, deleted_at TEXT)');
    repository = FolderRepository(database: AppDatabase.forTesting(() async => db));

    final batch = db.batch();
    for (var i = 0; i < 55; i++) {
      batch.insert('folders', {
        'id': 'folder-$i',
        'name': 'Folder ${i.toString().padLeft(3, '0')}',
        'sort_order': i,
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      });
    }
    batch.insert('folders', {
      'id': 'nested', 'name': 'Nested', 'parent_id': 'folder-0',
      'sort_order': 0,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    });
    batch.insert('folders', {
      'id': 'deleted', 'name': 'Deleted', 'deleted_at': '2026-11-01',
      'sort_order': 56,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    });
    await batch.commit(noResult: true);
  });

  tearDown(() async {
    await db.close();
  });

  test('background prefetch is bounded but normal interactive childrenOf stays complete', () async {
    final preview = await repository.childrenOf(null, previewLimit: 16);
    expect(preview, hasLength(16));
    expect(preview.first.name, 'Folder 000');
    expect(preview.last.name, 'Folder 015');

    // Old APIs are unaffected: tapping a folder still lists every child.
    final interactive = await repository.childrenOf(null);
    expect(interactive, hasLength(55));
    expect(interactive.last.name, 'Folder 054');
    expect(await repository.countDirectChildren(null), 55);
    expect(await repository.countDirectChildren('folder-0'), 1);
    expect(await repository.childrenOf('folder-0'), hasLength(1));
  });

  test('bad prefetch bounds are rejected before any provider read', () async {
    await expectLater(repository.childrenOf(null, previewLimit: 0),
        throwsArgumentError);
    await expectLater(repository.childrenOf(null, previewLimit: 25),
        throwsArgumentError);
    expect(await repository.childrenOf(null, previewLimit: 1), hasLength(1));
  });
}
