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
}
