import 'dart:math';

import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/tools/document_tools_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database database;
  late DocumentToolsService tools;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE documents (
              id TEXT PRIMARY KEY, name TEXT NOT NULL, storage_uri TEXT,
              deleted_at TEXT
            )
          ''');
          await db.execute('''
            CREATE TABLE document_text_index (
              document_id TEXT PRIMARY KEY, extracted_text TEXT NOT NULL
            )
          ''');
          await db.execute('CREATE INDEX idx_benchmark_doc_id ON documents(id)');
          await db.execute('CREATE INDEX idx_benchmark_text_doc ON document_text_index(document_id)');
        },
      ),
    );
    tools = DocumentToolsService(
      database: AppDatabase.forTesting(() async => database),
    );
  });

  tearDown(() async => database.close());

  test('OCR search benchmark: 10,000 indexed documents, warm p50/p95', () async {
    const count = 10000;
    await database.transaction((txn) async {
      final batch = txn.batch();
      for (var i = 0; i < count; i++) {
        final id = 'doc-${i.toString().padLeft(5, '0')}';
        batch.insert('documents', {
          'id': id, 'name': 'Document $i.pdf', 'storage_uri': '/bench/$id.pdf',
        });
        batch.insert('document_text_index', {
          'document_id': id,
          'extracted_text': i % 100 == 0
              ? 'Invoice reference BENCHMARK-HIT-$i amount 12500'
              : 'Ordinary policy document reference $i with searchable metadata',
        });
      }
      await batch.commit(noResult: true);
    });

    // Warm the SQLite/query path before measuring to reduce one-time setup noise.
    expect(await tools.searchText('BENCHMARK-HIT-'), hasLength(100));
    final samples = <int>[];
    for (var i = 0; i < 25; i++) {
      final watch = Stopwatch()..start();
      final results = await tools.searchText('BENCHMARK-HIT-');
      watch.stop();
      expect(results, hasLength(100));
      samples.add(watch.elapsedMicroseconds);
    }
    samples.sort();
    final p50 = samples[samples.length ~/ 2];
    final p95 = samples[(samples.length * .95).floor().clamp(0, samples.length - 1)];
    // A generous regression ceiling catches pathological scans/hangs without
    // pretending shared hosted runners are representative device hardware.
    expect(p95, lessThan(5000000), reason: 'OCR search p95 exceeded 5 seconds');
    // Emit stable machine-readable metrics in GitHub Actions logs.
    // ignore: avoid_print
    print('DOCSGRID_BENCHMARK search_docs=$count iterations=${samples.length} '
        'p50_us=$p50 p95_us=$p95');
  });
}
