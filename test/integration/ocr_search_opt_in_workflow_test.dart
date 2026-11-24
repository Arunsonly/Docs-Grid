import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/tools/document_tools_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeOnDeviceOcrService extends DocumentToolsService {
  _FakeOnDeviceOcrService({required AppDatabase appDatabase, required this.db})
      : super(database: appDatabase);

  final Database db;
  final List<String> calls = [];

  @override
  Future<int> indexPdfTextFromUri(
    String documentId,
    String storageUri, {
    bool Function()? shouldCancel,
  }) async {
    if (shouldCancel?.call() ?? false) throw const OcrIndexCancelled();
    calls.add(documentId);
    const extracted = '--- Page 1 ---\\nConfidential renewal reference 982731';
    await db.insert('document_text_index', {
      'document_id': documentId,
      'extracted_text': extracted,
      'indexed_at': '2026-11-21T00:00:00Z',
      'page_count': 1,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.update('documents', {'extracted_text_status': 'indexed'},
        where: 'id = ?', whereArgs: [documentId]);
    return extracted.length;
  }
}

void main() {
  late Database database;
  late _FakeOnDeviceOcrService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE documents (
              id TEXT PRIMARY KEY, name TEXT NOT NULL, storage_uri TEXT,
              extracted_text_status TEXT, deleted_at TEXT,
              created_at TEXT NOT NULL, updated_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE document_text_index (
              document_id TEXT PRIMARY KEY, extracted_text TEXT NOT NULL,
              indexed_at TEXT, page_count INTEGER
            )
          ''');
        },
      ),
    );
    service = _FakeOnDeviceOcrService(
      appDatabase: AppDatabase.forTesting(() async => database),
      db: database,
    );
    const stamp = '2026-11-21T00:00:00Z';
    for (final row in [
      {'id': 'a', 'name': 'Policy 2025', 'storage_uri': '/safe/policy.pdf',
        'extracted_text_status': 'pending'},
      {'id': 'b', 'name': 'Other document', 'storage_uri': '/safe/other.pdf',
        'extracted_text_status': 'indexed'},
      {'id': 'c', 'name': 'Missing policy', 'storage_uri': 'missing://c',
        'extracted_text_status': 'pending'},
      {'id': 'd', 'name': 'Empty previous OCR', 'storage_uri': '/safe/empty.pdf',
        'extracted_text_status': 'empty'},
    ]) {
      await database.insert('documents', {...row, 'created_at': stamp,
        'updated_at': stamp});
    }
    await database.insert('document_text_index', {
      'document_id': 'b', 'extracted_text': '--- Page 1 ---\\nSome other text',
      'indexed_at': stamp, 'page_count': 1,
    });
  });

  tearDown(() async => database.close());

  test('Retained OCR engine only indexes on an explicit call',
      () async {
    expect(service.calls, isEmpty);
    expect(await service.searchText('982731'), isEmpty);
    // File-name search cannot match a reference that appears only inside PDF.
    expect((await database.query('documents',
      where: 'name LIKE ?', whereArgs: ['%982731%'])), isEmpty);

    final progress = <String>[];
    final result = await service.indexPendingPdfsForSearch(
      onProgress: (done, total) => progress.add('$done/$total'),
    );
    expect(result.indexed, 1);
    expect(result.failed, 0);
    expect(result.skipped, 1); // Missing placeholder, never opened.
    expect(progress, ['1/1']);
    expect(service.calls, ['a']);
    expect((await service.searchText('982731')).map((r) => r['id']), ['a']);

    // Search again without rescanning an already indexed PDF.
    await service.indexPendingPdfsForSearch();
    expect(service.calls, ['a']);
  });

  test('cancellation stops subsequent PDFs without removing existing indexes',
      () async {
    await database.insert('documents', {
      'id': 'e', 'name': 'New document', 'storage_uri': '/safe/extra.pdf',
      'extracted_text_status': 'pending',
      'created_at': '2026-11-21T00:00:01Z',
      'updated_at': '2026-11-21T00:00:01Z',
    });
    var cancel = false;
    await expectLater(
      service.indexPendingPdfsForSearch(
        shouldCancel: () => cancel,
        onProgress: (_, __) => cancel = true,
      ),
      throwsA(isA<OcrIndexCancelled>()),
    );
    expect(service.calls, ['a']);
    expect((await service.searchText('982731')).map((r) => r['id']), ['a']);
  });
}
