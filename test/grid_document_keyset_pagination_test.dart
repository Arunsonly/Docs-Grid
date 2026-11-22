import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/documents/data/document_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late DocumentRepository repository;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE documents (
        id TEXT PRIMARY KEY, name TEXT NOT NULL,
        storage_uri TEXT, size_bytes INTEGER DEFAULT 0,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        deleted_at TEXT, folder_id TEXT, category_id TEXT,
        is_favorite INTEGER DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX idx_folder_active ON documents(folder_id, deleted_at)');
    await db.execute('CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT)');
    await db.execute('CREATE TABLE tags (id TEXT PRIMARY KEY, name TEXT)');
    await db.execute('CREATE TABLE document_tags (document_id TEXT, tag_id TEXT)');
    repository = DocumentRepository(database: AppDatabase.forTesting(() async => db));
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> add(String id, String name, String? folder, {bool deleted = false}) =>
      db.insert('documents', {
        'id': id,
        'name': name,
        'folder_id': folder,
        'deleted_at': deleted ? '2026-11-01T00:00:00Z' : null,
        'storage_uri': 'content://media/$id',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      }).then((_) {});

  test('loads exactly 60 PDFs on the first page, then the rest without duplicates', () async {
    for (var i = 0; i < 153; i++) {
      await add('f-${i.toString().padLeft(3, '0')}',
          'Policy_${i.toString().padLeft(3, '0')}', 'folder-A');
    }
    await add('other', 'Another_folder', 'folder-B');
    await add('root', 'Root_record', null);
    await add('trash', 'Deleted', 'folder-A', deleted: true);
    expect(await repository.countInFolder('folder-A'), 153);
    expect(await repository.countInFolder('folder-B'), 1);
    expect(await repository.countInFolder(null), 1);

    final first = await repository.listInFolderPage('folder-A');
    expect(first.records, hasLength(60));
    expect(first.hasMore, isTrue);
    expect(first.nextName, first.records.last.name);
    final second = await repository.listInFolderPage('folder-A',
      afterName: first.nextName, afterId: first.nextId);
    expect(second.records, hasLength(60));
    expect(second.hasMore, isTrue);
    final third = await repository.listInFolderPage('folder-A',
      afterName: second.nextName, afterId: second.nextId);
    expect(third.records, hasLength(33));
    expect(third.hasMore, isFalse);
    final seen = [...first.records, ...second.records, ...third.records];
    expect(seen.map((item) => item.id).toSet(), hasLength(153));
    expect(seen.map((item) => item.name).first, 'Policy_000');
    expect(seen.map((item) => item.name).last, 'Policy_152');
  });

  test('case-insensitive name ties use ID cursor without dropping PDFs', () async {
    await add('a', 'Policy', 'A');
    await add('b', 'policy', 'A');
    await add('c', 'POLICY', 'A');
    await add('d', 'Zulu', 'A');
    final items = <DocumentRecord>[];
    String? nextName;
    String? nextId;
    for (var i = 0; i < 10; i++) {
      final page = await repository.listInFolderPage(
        'A', pageSize: 1, afterName: nextName, afterId: nextId,
      );
      items.addAll(page.records);
      if (!page.hasMore) break;
      nextName = page.nextName;
      nextId = page.nextId;
    }
    expect(items.map((item) => item.id), ['a', 'b', 'c', 'd']);
  });

  test('missing, empty and deleted folders produce zero without ghosts', () async {
    await add('deleted', 'no.pdf', 'folder-A', deleted: true);
    final page = await repository.listInFolderPage('folder-A');
    expect(page.records, isEmpty);
    expect(page.hasMore, isFalse);
    expect(await repository.countInFolder('folder-A'), 0);
    expect(await repository.listInFolderPage('unknown').then((p) => p.records), isEmpty);
  });

  test('unbounded and incomplete cursor requests are rejected', () async {
    expect(() => repository.listInFolderPage(null, pageSize: 0),
        throwsArgumentError);
    expect(() => repository.listInFolderPage(null, pageSize: 5000),
        throwsArgumentError);
    expect(() => repository.listInFolderPage(null, afterName: 'A'),
        throwsArgumentError);
  });
}
