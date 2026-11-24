import 'dart:io';
import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/documents/data/document_repository.dart';
import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('clean installation opens the real empty Grid without storage provider calls', () async {
    final root = await Directory.systemTemp.createTemp('docsgrid_empty_grid_');
    addTearDown(() => root.delete(recursive: true));
    final schema = AppDatabase.forTesting(() => throw StateError('unused'));
    var opens = 0;
    final database = AppDatabase.forTesting(() async {
      opens++;
      return schema.openProductionSchemaForTesting('${root.path}/docs_grid.db');
    });
    final folders = FolderRepository(database: database);
    final docs = DocumentRepository(database: database);
    // Same concurrent queries as the first Grid screen plus first-launch
    // recovery's user-data check. No fake repository or provider grant.
    final result = await Future.wait<Object>([
      folders.childrenOf(null),
      docs.listInFolderPage(null),
      docs.countInFolder(null),
      database.hasPortableUserData(),
    ]).timeout(const Duration(seconds: 10));
    expect(opens, 1);
    expect(result[0], isEmpty);
    expect((result[1] as FolderDocumentPage).records, isEmpty);
    expect(result[2], 0);
    expect(result[3], isFalse);
    await (await database.database).close();
  });
}
