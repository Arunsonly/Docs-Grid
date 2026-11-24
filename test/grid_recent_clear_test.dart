import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/documents/data/document_repository.dart';
import 'package:docs_grid/features/documents/data/grid_recent_history.dart';
import 'package:docs_grid/features/documents/data/home_dashboard_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Grid Recent clear hides older created PDFs but never deletes them',
      () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    try {
      await db.execute('CREATE TABLE documents ('
          'id TEXT PRIMARY KEY, name TEXT NOT NULL, '
          'created_at TEXT NOT NULL, last_opened_at TEXT, '
          'deleted_at TEXT, category_id TEXT, storage_uri TEXT, '
          'size_bytes INTEGER, is_favorite INTEGER)');
      await db.execute('CREATE TABLE categories (id TEXT, name TEXT)');
      await db.execute('CREATE TABLE tags (id TEXT, name TEXT)');
      await db.execute(
          'CREATE TABLE document_tags (document_id TEXT, tag_id TEXT)');

      final oldAt = DateTime.utc(2026, 11, 22, 10);
      final clearedAt = DateTime.utc(2026, 11, 23, 10);
      final after = DateTime.utc(2026, 11, 23, 11);

      Future<void> addDocument(String id, DateTime created,
          {DateTime? opened}) => db.insert('documents', {
        'id': id,
        'name': id,
        'created_at': created.toIso8601String(),
        'last_opened_at': opened?.toIso8601String(),
      }).then((_) {});

      await addDocument('old-never-opened', oldAt);
      await addDocument('old-opened', oldAt,
          opened: oldAt.add(const Duration(hours: 1)));
      final repository = DocumentRepository(
          database: AppDatabase.forTesting(() async => db));
      expect((await repository.recentActivity()).length, 2);

      await GridRecentHistory.markCleared(clearedAt);
      final since = await GridRecentHistory.lastClearedAt();
      expect(since, clearedAt);
      expect(await repository.recentActivity(since: since), isEmpty);

      // The real Grid records must be untouched by clearing Recent.
      expect(await db.query('documents'), hasLength(2));

      // A newly added PDF and an older PDF opened after Clear both reappear.
      await addDocument('new-document', after);
      await db.update('documents',
          {'last_opened_at': after.add(const Duration(minutes: 2))
              .toIso8601String()},
          where: 'id = ?', whereArgs: ['old-opened']);
      final refreshed = await repository.recentActivity(
          since: await GridRecentHistory.lastClearedAt());
      expect(refreshed.map((d) => d.id).toSet(),
          {'new-document', 'old-opened'});
      expect(refreshed.any((d) => d.id == 'old-never-opened'), isFalse);

      // Cached names cannot restore an outdated Recent panel after restart.
      final cache = HomeDashboardCache();
      await cache.saveRecentNames(['old-never-opened']);
      await cache.saveRecentNames([]);
      expect(await HomeDashboardCache().readRecentNames(), isEmpty);
      expect((await repository.recentActivity()).length, 3);
    } finally {
      await db.close();
    }
  });

  test('empty clear marker leaves previously stored Recent entries readable',
      () async {
    expect(await GridRecentHistory.lastClearedAt(), isNull);
    await GridRecentHistory.markCleared(
        DateTime.parse('2026-11-24T09:30:00+05:30'));
    expect(await GridRecentHistory.lastClearedAt(),
        DateTime.utc(2026, 11, 24, 4));
  });
}
