import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/categories/data/category_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database database;
  late CategoryRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE categories (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL UNIQUE COLLATE NOCASE,
              is_builtin INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE tags (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL UNIQUE COLLATE NOCASE,
              created_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE documents (
              id TEXT PRIMARY KEY,
              category_id TEXT,
              deleted_at TEXT,
              updated_at TEXT,
              FOREIGN KEY(category_id) REFERENCES categories(id) ON DELETE SET NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE document_tags (
              document_id TEXT NOT NULL,
              tag_id TEXT NOT NULL,
              PRIMARY KEY(document_id, tag_id),
              FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE CASCADE,
              FOREIGN KEY(tag_id) REFERENCES tags(id) ON DELETE CASCADE
            )
          ''');
          await db.execute('''
            CREATE TABLE history (
              id TEXT PRIMARY KEY,
              document_id TEXT,
              action TEXT NOT NULL,
              details_json TEXT NOT NULL,
              created_at TEXT NOT NULL,
              FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE SET NULL
            )
          ''');
          await db.insert('documents', {'id': 'doc-1'});
        },
      ),
    );
    repository = CategoryRepository(database: AppDatabase.forTesting(() async => database));
  });

  tearDown(() async {
    await database.close();
  });

  test('category and tag assignments are recorded in the same database history', () async {
    final category = await repository.createCategory('Insurance');
    final tag = await repository.createTag('Renewal');

    await repository.setDocumentCategory('doc-1', category.id);
    await repository.setDocumentTags('doc-1', [tag.id]);

    final document = (await database.query('documents', where: 'id = ?', whereArgs: ['doc-1'])).single;
    expect(document['category_id'], category.id);

    final actions = (await database.query('history', columns: ['action']))
        .map((row) => row['action'])
        .toSet();
    expect(actions, containsAll({
      'category_created',
      'tag_created',
      'category_changed',
      'tags_changed',
    }));
  });
}
