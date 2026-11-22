import 'dart:convert';

import 'package:docs_grid/features/documents/data/home_dashboard_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('summary snapshot round-trips with bounded nonnegative metadata only', () async {
    final cache = HomeDashboardCache();
    await cache.saveSummary(
      documentCount: 173, favoriteCount: 5, totalBytes: 999999,
    );
    final value = await cache.readSummary();
    expect(value, isNotNull);
    expect(value!.documentCount, 173);
    expect(value.favoriteCount, 5);
    expect(value.totalBytes, 999999);
    final prefs = await SharedPreferences.getInstance();
    final source = jsonDecode(prefs.getString(HomeDashboardCache.summaryKey)!);
    expect(source.keys.toSet(), {
      'version', 'savedAtUtc', 'documentCount', 'favoriteCount', 'totalBytes',
    });
    expect(source.toString(), isNot(contains('storagePath')));
    expect(source.toString(), isNot(contains('contentUri')));
  });

  test('rejects invalid, expired and future-dated stale summaries', () {
    final now = DateTime.utc(2026, 11, 20, 10);
    String encode(Object value) => jsonEncode(value);
    expect(CachedHomeSummary.decode('not-json', now), isNull);
    expect(CachedHomeSummary.decode(encode({'version': 2}), now), isNull);
    expect(CachedHomeSummary.decode(encode({
      'version': 1,
      'savedAtUtc': now.subtract(const Duration(days: 8)).toIso8601String(),
      'documentCount': 10, 'favoriteCount': 1, 'totalBytes': 42,
    }), now), isNull);
    expect(CachedHomeSummary.decode(encode({
      'version': 1,
      'savedAtUtc': now.add(const Duration(hours: 3)).toIso8601String(),
      'documentCount': 10, 'favoriteCount': 1, 'totalBytes': 42,
    }), now), isNull);
    expect(CachedHomeSummary.decode(encode({
      'version': 1, 'savedAtUtc': now.toIso8601String(),
      'documentCount': 1, 'favoriteCount': 2, 'totalBytes': 42,
    }), now), isNull);
    expect(CachedHomeSummary.decode(encode({
      'version': 1, 'savedAtUtc': now.toIso8601String(),
      'documentCount': 1, 'favoriteCount': 1, 'totalBytes': -1,
    }), now), isNull);
  });

  test('recent preview stores only bounded labels and never a PDF action', () async {
    final cache = HomeDashboardCache();
    final names = List<String>.generate(25, (i) => 'Document $i');
    await cache.saveRecentNames(names);
    final readBack = await cache.readRecentNames();
    expect(readBack, names.take(8).toList());
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(HomeDashboardCache.recentNamesKey)!;
    final snapshot = jsonDecode(raw) as Map<String, dynamic>;
    expect(snapshot.keys.toSet(), {'version', 'savedAtUtc', 'names'});
    expect(raw, isNot(contains('storagePath')));
    expect(raw, isNot(contains('contentUri')));
    expect(raw, isNot(contains('documentId')));
  });

  test('corrupt recent list is ignored, and valid empty list clears preview', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(HomeDashboardCache.recentNamesKey, jsonEncode({
      'version': 1,
      'savedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'names': ['ok', null],
    }));
    final cache = HomeDashboardCache();
    expect(await cache.readRecentNames(), isEmpty);
    await cache.saveRecentNames(['Earlier PDF']);
    expect(await cache.readRecentNames(), ['Earlier PDF']);
    await cache.saveRecentNames([]);
    expect(await cache.readRecentNames(), isEmpty);
  });

  test('negative or impossible summary never overwrites a valid snapshot', () async {
    final cache = HomeDashboardCache();
    await cache.saveSummary(documentCount: 12, favoriteCount: 1, totalBytes: 54);
    await cache.saveSummary(documentCount: 1, favoriteCount: 2, totalBytes: 30);
    expect((await cache.readSummary())?.documentCount, 12);
  });
  test('process recreation reads persistent summary and recent labels without PDF actions', () async {
    final firstSession = HomeDashboardCache();
    await firstSession.saveSummary(
      documentCount: 4, favoriteCount: 1, totalBytes: 2048,
    );
    await firstSession.saveRecentNames(['A', 'B']);
    // Simulates a new Dart widget/repository session, keeping the same
    // SharedPreferences backing store exactly as an Android force-stop does.
    final nextSession = HomeDashboardCache();
    final summary = await nextSession.readSummary();
    expect(summary, isNotNull);
    expect(summary!.documentCount, 4);
    expect(summary.favoriteCount, 1);
    expect(summary.totalBytes, 2048);
    expect(await nextSession.readRecentNames(), ['A', 'B']);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(HomeDashboardCache.recentNamesKey)!;
    expect(raw, isNot(contains('storage_uri')));
    expect(raw, isNot(contains('documentId')));
    expect(raw, isNot(contains('pdfBytes')));
  });

  test('newer live summary and recent values replace prior-session snapshot', () async {
    final cache = HomeDashboardCache();
    await cache.saveSummary(documentCount: 11, favoriteCount: 3, totalBytes: 1100);
    await cache.saveRecentNames(['Old document']);
    final resumed = HomeDashboardCache();
    expect((await resumed.readSummary())?.documentCount, 11);
    expect(await resumed.readRecentNames(), ['Old document']);
    // These writes mirror the existing live SQLite success callbacks.
    await resumed.saveSummary(documentCount: 12, favoriteCount: 2, totalBytes: 1300);
    await resumed.saveRecentNames(['New document', 'Old document']);
    final nextRelaunch = HomeDashboardCache();
    final latest = await nextRelaunch.readSummary();
    expect(latest?.documentCount, 12);
    expect(latest?.favoriteCount, 2);
    expect(latest?.totalBytes, 1300);
    expect(await nextRelaunch.readRecentNames(), ['New document', 'Old document']);
  });

  test('overlapping summary writes serialize so late old values cannot win', () async {
    final cache = HomeDashboardCache();
    // The implementation queues writes. A delayed initial write must not
    // overwrite the final real SQLite counts after a burst of mutations.
    await Future.wait([
      cache.saveSummary(documentCount: 1, favoriteCount: 0, totalBytes: 10),
      cache.saveSummary(documentCount: 2, favoriteCount: 0, totalBytes: 30),
      cache.saveSummary(documentCount: 3, favoriteCount: 1, totalBytes: 60),
    ]);
    final latest = await HomeDashboardCache().readSummary();
    expect(latest?.documentCount, 3);
    expect(latest?.favoriteCount, 1);
    expect(latest?.totalBytes, 60);
  });

  test('a fully removed library clears prior PDF counts and recent labels', () async {
    final cache = HomeDashboardCache();
    await cache.saveSummary(documentCount: 3, favoriteCount: 1, totalBytes: 987);
    await cache.saveRecentNames(['A', 'B']);
    await cache.saveSummary(documentCount: 0, favoriteCount: 0, totalBytes: 0);
    await cache.saveRecentNames([]);
    final relaunched = HomeDashboardCache();
    expect((await relaunched.readSummary())?.documentCount, 0);
    expect((await relaunched.readSummary())?.totalBytes, 0);
    expect(await relaunched.readRecentNames(), isEmpty);
  });

}
