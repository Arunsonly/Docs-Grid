import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/documents/data/document_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database database;
  late DocumentRepository repository;

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
              id TEXT PRIMARY KEY, name TEXT NOT NULL, original_name TEXT,
              storage_uri TEXT, relative_path TEXT, mime_type TEXT NOT NULL,
              size_bytes INTEGER NOT NULL, sha256 TEXT, folder_id TEXT,
              category_id TEXT, extracted_text_status TEXT, expiry_date TEXT,
              created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
              last_opened_at TEXT, deleted_at TEXT, source TEXT, metadata_json TEXT,
              is_favorite INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await db.execute('CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT NOT NULL)');
          await db.execute('CREATE TABLE tags (id TEXT PRIMARY KEY, name TEXT NOT NULL)');
          await db.execute('CREATE TABLE document_tags (document_id TEXT, tag_id TEXT)');
          await db.execute('CREATE INDEX idx_bench_documents_deleted ON documents(deleted_at)');
        },
      ),
    );
    repository = DocumentRepository(
      database: AppDatabase.forTesting(() async => database),
    );
  });

  tearDown(() async => database.close());

  test('dashboard aggregate and keyset pages return exact, non-overlapping results', () async {
    const count = 125;
    const stamp = '2026-11-09T00:00:00.000Z';
    await database.transaction((txn) async {
      final batch = txn.batch();
      for (var i = 0; i < count; i++) {
        batch.insert('documents', {
          'id': 'page-${i.toString().padLeft(3, '0')}',
          'name': 'Document ${i.toString().padLeft(3, '0')}',
          'mime_type': 'application/pdf',
          'size_bytes': 100 + i,
          'created_at': stamp,
          'updated_at': stamp,
          'metadata_json': '{}',
          'is_favorite': i % 5 == 0 ? 1 : 0,
          'deleted_at': i == 124 ? stamp : null,
        });
      }
      await batch.commit(noResult: true);
    });

    final summary = await repository.dashboardSummary();
    expect(summary.documentCount, 124);
    expect(summary.favoriteCount, 25);
    expect(summary.totalBytes, List<int>.generate(124, (i) => 100 + i).reduce((a, b) => a + b));

    final ids = <String>[];
    DocumentPageCursor? cursor;
    var pageCount = 0;
    do {
      final page = await repository.listPage(pageSize: 30, cursor: cursor);
      pageCount++;
      ids.addAll(page.items.map((item) => item.id));
      cursor = page.nextCursor;
      if (!page.hasMore) break;
    } while (pageCount < 10);
    expect(pageCount, 5);
    expect(ids, hasLength(124));
    expect(ids.toSet(), hasLength(124));
    expect(ids, isNot(contains('page-124')));

    final favorites = await repository.listPage(favoritesOnly: true, pageSize: 100);
    expect(favorites.items, hasLength(25));
    expect(favorites.items.every((item) => item.isFavorite), isTrue);
  });

  test('real document repository list benchmark: 10,000 documents', () async {
    const count = 10000;
    const stamp = '2026-11-09T00:00:00.000Z';
    await database.transaction((txn) async {
      final batch = txn.batch();
      for (var i = 0; i < count; i++) {
        final id = 'doc-${i.toString().padLeft(5, '0')}';
        batch.insert('documents', {
          'id': id,
          'name': 'Policy document $i.pdf',
          'mime_type': 'application/pdf',
          'size_bytes': 4096 + i,
          'created_at': stamp,
          'updated_at': stamp,
          'metadata_json': i % 10 == 0 ? '{"favorite":true}' : '{}',
          'is_favorite': i % 10 == 0 ? 1 : 0,
          'deleted_at': null,
        });
      }
      await batch.commit(noResult: true);
    });

    final warm = await repository.list();
    expect(warm, hasLength(count));
    final samples = <int>[];
    for (var i = 0; i < 15; i++) {
      final watch = Stopwatch()..start();
      final rows = await repository.list();
      watch.stop();
      expect(rows, hasLength(count));
      samples.add(watch.elapsedMicroseconds);
    }
    samples.sort();
    final p50 = samples[samples.length ~/ 2];
    final p95 = samples[(samples.length * .95).floor().clamp(0, samples.length - 1)];
    expect(p95, lessThan(5000000), reason: '10k document repository list p95 exceeded 5 seconds');
    // ignore: avoid_print
    print('DOCSGRID_BENCHMARK list_docs=$count iterations=${samples.length} '
        'p50_us=$p50 p95_us=$p95');
  });
}
