import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/tools/document_tools_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database database;
  late DocumentToolsService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE documents (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              storage_uri TEXT,
              deleted_at TEXT
            )
          ''');
          await db.execute('''
            CREATE TABLE document_text_index (
              document_id TEXT PRIMARY KEY,
              extracted_text TEXT NOT NULL
            )
          ''');
          final rows = [
            ('doc-percent', 'Percentage.pdf', 'Policy is 100% complete'),
            ('doc-plain', 'Plain.pdf', 'Policy is complete'),
            ('doc-underscore', 'Underscore.pdf', 'Policy_number is present'),
            ('doc-other', 'Other.pdf', 'Policy number is present'),
          ];
          for (final row in rows) {
            await db.insert('documents', {
              'id': row.$1, 'name': row.$2, 'storage_uri': '/tmp/${row.$1}.pdf',
            });
            await db.insert('document_text_index', {
              'document_id': row.$1, 'extracted_text': row.$3,
            });
          }
        },
      ),
    );
    service = DocumentToolsService(database: AppDatabase.forTesting(() async => database));
  });

  tearDown(() async {
    await database.close();
  });

  test('percent and underscore are searched as literal OCR characters', () async {
    final percent = await service.searchText('%');
    final underscore = await service.searchText('_');

    expect(percent.map((row) => row['id']).toList(), ['doc-percent']);
    expect(underscore.map((row) => row['id']).toList(), ['doc-underscore']);
  });
}
