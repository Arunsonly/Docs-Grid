import 'package:shared_preferences/shared_preferences.dart';

/// A non-destructive marker for Grid Recent. Older PDFs remain in the library;
/// they only disappear from the Recent panel until opened again.
class GridRecentHistory {
  const GridRecentHistory._();

  static const clearedAtKey = 'docsgrid_grid_recent_cleared_at_utc_v1';

  static Future<DateTime?> lastClearedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(clearedAtKey);
    if (raw == null) return null;
    final parsed = DateTime.tryParse(raw);
    return parsed?.toUtc();
  }

  static Future<void> markCleared(DateTime instant) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(clearedAtKey,
        instant.toUtc().toIso8601String())) {
      throw StateError('Grid Recent clear marker could not be saved.');
    }
  }
}
