import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late FolderRepository folders;

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
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
    folders = FolderRepository(database: AppDatabase.forTesting(() async => db));
  });

  tearDown(() async => db.close());

  test('recovery reuses existing Grid parent and nested folders by case-insensitive name', () async {
    final existingParent = await folders.create(name: 'RAS');
    final existingChild = await folders.create(
      name: 'Political Science',
      parentId: existingParent.id,
    );

    final first = await folders.ensureRecoveredFolderPath('ras/political science');
    final second = await folders.ensureRecoveredFolderPath('RAS/Political Science');

    expect(first, existingChild.id);
    expect(second, existingChild.id);
    expect((await db.query('folders')).length, 2);
  });

  test('recovery creates only the missing child under an existing Grid parent', () async {
    final parent = await folders.create(name: 'Studies');
    final result = await folders.ensureRecoveredFolderPath('studies/2025');

    final rows = await db.query('folders', orderBy: 'name ASC');
    expect(rows, hasLength(2));
    expect(rows.singleWhere((row) => row['name'] == 'Studies')['id'], parent.id);
    expect(rows.singleWhere((row) => row['name'] == '2025')['parent_id'], parent.id);
    expect(result, rows.singleWhere((row) => row['name'] == '2025')['id']);
  });

  test('recovery path rejects traversal and leaves folders unchanged', () async {
    await expectLater(
      folders.ensureRecoveredFolderPath('valid/../escape'),
      throwsArgumentError,
    );
    expect(await db.query('folders'), isEmpty);
  });
}
