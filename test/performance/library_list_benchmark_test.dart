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
          await db.execute('CREATE TABLE document_summary_state (id INTEGER PRIMARY KEY, revision INTEGER NOT NULL)');
          await db.insert('document_summary_state', {'id': 1, 'revision': 0});
          await db.execute('CREATE TRIGGER documents_summary_after_insert AFTER INSERT ON documents BEGIN UPDATE document_summary_state SET revision = revision + 1 WHERE id = 1; END');
          await db.execute('CREATE TRIGGER documents_summary_after_update AFTER UPDATE ON documents BEGIN UPDATE document_summary_state SET revision = revision + 1 WHERE id = 1; END');
          await db.execute('CREATE TRIGGER documents_summary_after_delete AFTER DELETE ON documents BEGIN UPDATE document_summary_state SET revision = revision + 1 WHERE id = 1; END');
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

  test('dashboard summary cache refreshes after trigger-observed external mutations', () async {
    await database.insert('documents', {
      'id': 'cache-1', 'name': 'cache.pdf', 'mime_type': 'application/pdf',
      'size_bytes': 100, 'created_at': '2026-11-09T00:00:00.000Z',
      'updated_at': '2026-11-09T00:00:00.000Z', 'metadata_json': '{}',
      'is_favorite': 0,
    });
    final first = await repository.dashboardSummary();
    final second = await repository.dashboardSummary();
    expect(identical(first, second), isTrue);
    expect(first.documentCount, 1);
    await database.update('documents', {'is_favorite': 1, 'size_bytes': 250},
        where: 'id = ?', whereArgs: ['cache-1']);
    final afterUpdate = await repository.dashboardSummary();
    expect(identical(afterUpdate, first), isFalse);
    expect(afterUpdate.favoriteCount, 1);
    expect(afterUpdate.totalBytes, 250);
    await database.delete('documents', where: 'id = ?', whereArgs: ['cache-1']);
    final afterDelete = await repository.dashboardSummary();
    expect(afterDelete.documentCount, 0);
    expect(afterDelete.totalBytes, 0);
  });

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

  test('100k document scale: summary and first keyset page stay bounded', () async {
    const count = 100000;
    const stamp = '2026-11-09T00:00:00.000Z';
    for (var start = 0; start < count; start += 5000) {
      await database.transaction((txn) async {
        final batch = txn.batch();
        final end = (start + 5000).clamp(0, count);
        for (var i = start; i < end; i++) {
          batch.insert('documents', {
            'id': 'scale-${i.toString().padLeft(6, '0')}',
            'name': 'Archive policy ${i.toString().padLeft(6, '0')}.pdf',
            'mime_type': 'application/pdf',
            'size_bytes': 2048 + (i % 4096),
            'created_at': stamp,
            'updated_at': stamp,
            'metadata_json': '{}',
            'is_favorite': i % 20 == 0 ? 1 : 0,
            'deleted_at': null,
          });
        }
        await batch.commit(noResult: true);
      });
    }
    final watch = Stopwatch()..start();
    final summary = await repository.dashboardSummary();
    watch.stop();
    expect(summary.documentCount, count);
    expect(summary.favoriteCount, count ~/ 20);
    final summaryUs = watch.elapsedMicroseconds;

    final samples = <int>[];
    for (var i = 0; i < 12; i++) {
      final pageWatch = Stopwatch()..start();
      final page = await repository.listPage(pageSize: 40);
      pageWatch.stop();
      expect(page.items, hasLength(40));
      expect(page.hasMore, isTrue);
      samples.add(pageWatch.elapsedMicroseconds);
    }
    samples.sort();
    final p50 = samples[samples.length ~/ 2];
    final p95 = samples[(samples.length * .95).floor().clamp(0, samples.length - 1)];
    // ignore: avoid_print
    print('DOCSGRID_SCALE rows=$count page_size=40 p50_us=$p50 p95_us=$p95 summary_us=$summaryUs');
    expect(p95, lessThan(5000000), reason: '100k first-page p95 exceeded 5 seconds');
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
    // Measure the bounded page path separately from the legacy full-list
    // API so CI reports the cost users pay when opening the first screen.
    final pageSamples = <int>[];
    for (var i = 0; i < 20; i++) {
      final watch = Stopwatch()..start();
      final page = await repository.listPage(pageSize: 40);
      watch.stop();
      expect(page.items, hasLength(40));
      expect(page.hasMore, isTrue);
      pageSamples.add(watch.elapsedMicroseconds);
    }
    pageSamples.sort();
    final pageP50 = pageSamples[pageSamples.length ~/ 2];
    final pageP95 = pageSamples[(pageSamples.length * .95).floor().clamp(0, pageSamples.length - 1)];
    final summaryWatch = Stopwatch()..start();
    final summary = await repository.dashboardSummary();
    summaryWatch.stop();
    expect(summary.documentCount, count);
    expect(summary.favoriteCount, count ~/ 10);
    // ignore: avoid_print
    print('DOCSGRID_BENCHMARK list_docs=$count iterations=${samples.length} '
        'full_list_p50_us=$p50 full_list_p95_us=$p95 '
        'page_size=40 page_p50_us=$pageP50 page_p95_us=$pageP95 '
        'summary_us=${summaryWatch.elapsedMicroseconds}');
  });
}
