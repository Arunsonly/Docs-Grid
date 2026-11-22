import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// An optional, bounded, app-private *presentation-only* Home snapshot.
///
/// No document IDs, storage paths, content URIs, bytes, actions or permissions
/// are persisted here. The real SQLite and provider records always win.
class CachedHomeSummary {
  const CachedHomeSummary({
    required this.documentCount,
    required this.favoriteCount,
    required this.totalBytes,
  });

  final int documentCount;
  final int favoriteCount;
  final int totalBytes;

  static CachedHomeSummary? decode(String? raw, DateTime now) {
    if (raw == null || raw.length > 1024) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['version'] != 1) return null;
      final savedAt = DateTime.tryParse(value['savedAtUtc'] as String? ?? '');
      if (savedAt == null ||
          savedAt.isAfter(now.toUtc().add(const Duration(minutes: 2))) ||
          now.toUtc().difference(savedAt) > const Duration(days: 7)) {
        return null;
      }
      final count = value['documentCount'];
      final favorites = value['favoriteCount'];
      final bytes = value['totalBytes'];
      if (count is! int || count < 0 || count > 100000000 ||
          favorites is! int || favorites < 0 || favorites > count ||
          bytes is! int || bytes < 0) return null;
      return CachedHomeSummary(
        documentCount: count,
        favoriteCount: favorites,
        totalBytes: bytes,
      );
    } catch (_) {
      return null;
    }
  }
}

class HomeDashboardCache {
  static const summaryKey = 'docsgrid_home_summary_v1';
  static const recentNamesKey = 'docsgrid_home_recent_names_v1';
  static const int maxRecentNames = 8;
  static Future<void> _summaryWrites = Future<void>.value();
  static Future<void> _recentWrites = Future<void>.value();

  Future<CachedHomeSummary?> readSummary() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return CachedHomeSummary.decode(
        prefs.getString(summaryKey), DateTime.now().toUtc(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> readRecentNames() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(recentNamesKey);
      if (raw == null || raw.length > 2048) return const [];
      final value = jsonDecode(raw);
      if (value is! Map || value['version'] != 1) return const [];
      final savedAt = DateTime.tryParse(value['savedAtUtc'] as String? ?? '');
      if (savedAt == null ||
          savedAt.isAfter(DateTime.now().toUtc().add(const Duration(minutes: 2))) ||
          DateTime.now().toUtc().difference(savedAt) > const Duration(days: 7)) {
        return const [];
      }
      final names = value['names'];
      if (names is! List || names.length > maxRecentNames) return const [];
      if (names.any((name) =>
          name is! String || name.isEmpty || name.length > 160)) return const [];
      return List<String>.unmodifiable(names.cast<String>());
    } catch (_) {
      return const [];
    }
  }

  /// A best-effort serialized write; never invoked on the critical render path.
  Future<void> saveSummary({
    required int documentCount,
    required int favoriteCount,
    required int totalBytes,
  }) {
    if (documentCount < 0 || favoriteCount < 0 ||
        favoriteCount > documentCount || totalBytes < 0) {
      return Future<void>.value();
    }
    _summaryWrites = _summaryWrites.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(summaryKey, jsonEncode({
          'version': 1,
          'savedAtUtc': DateTime.now().toUtc().toIso8601String(),
          'documentCount': documentCount,
          'favoriteCount': favoriteCount,
          'totalBytes': totalBytes,
        }));
      } catch (_) {
        // Optional presentation cache must never interrupt library actions.
      }
    });
    return _summaryWrites;
  }

  Future<void> saveRecentNames(List<String> names) {
    final bounded = names.take(maxRecentNames)
        .where((name) => name.isNotEmpty)
        .map((name) => name.length > 160 ? name.substring(0, 160) : name)
        .toList(growable: false);
    _recentWrites = _recentWrites.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(recentNamesKey, jsonEncode({
          'version': 1,
          'savedAtUtc': DateTime.now().toUtc().toIso8601String(),
          'names': bounded,
        }));
      } catch (_) {
        // A cache failure cannot affect recent history or actual documents.
      }
    });
    return _recentWrites;
  }
}
