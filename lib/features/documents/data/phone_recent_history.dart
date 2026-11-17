import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The Phone Recent panel tracks external URI *references*, not file copies.
/// A successful Phone -> Grid move invalidates the source URI; never keep a
/// shortcut to an item which is now owned by the Grid library.
class PhoneRecentHistory {
  const PhoneRecentHistory._();

  static const storageKey = 'docsgrid_phone_recent_v1';

  /// A move is considered complete only after the source was deleted by the
  /// storage provider. Remove that *exact* URI without disturbing any other
  /// recent items, including entries in older or unknown formats.
  static Future<bool> removeMovedSource(String uri) async {
    if (uri.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    return removeMovedSourceFromPreferences(prefs, uri);
  }

  static Future<bool> removeMovedSourceFromPreferences(
      SharedPreferences prefs, String uri) async {
    final saved = prefs.getStringList(storageKey) ?? const <String>[];
    final kept = <String>[];
    for (final raw in saved) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['uri'] == uri) continue;
      } catch (_) {
        // Unknown older preference entries should be left untouched.
      }
      kept.add(raw);
    }
    if (kept.length == saved.length) return false;
    if (!await prefs.setStringList(storageKey, kept)) {
      throw StateError('Could not persist the moved PDF recent-history change.');
    }
    return true;
  }

  /// Only a *complete* MediaStore index is authoritative about which media
  /// item URIs still exist. Do not remove SAF, file:// or other provider
  /// references, and do not run this on partial scans or permission failures.
  static Future<int> pruneAbsentMediaStoreUris(
      Set<String> availableMediaUris, {
      required Set<String> scannedVolumes,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    return pruneAbsentMediaStoreUrisFromPreferences(
        prefs, availableMediaUris, scannedVolumes: scannedVolumes);
  }

  static Future<int> pruneAbsentMediaStoreUrisFromPreferences(
      SharedPreferences prefs, Set<String> availableMediaUris, {
      required Set<String> scannedVolumes,
  }) async {
    final saved = prefs.getStringList(storageKey) ?? const <String>[];
    final kept = <String>[];
    var removed = 0;
    for (final raw in saved) {
      try {
        final decoded = jsonDecode(raw);
        final uri = decoded is Map ? decoded['uri'] : null;
        if (uri is String && uri.startsWith('content://media/')) {
          // A complete scan of mounted storage cannot establish anything
          // about disconnected SD cards or unindexed/legacy URI volumes.
          final parsed = Uri.tryParse(uri);
          final volume = parsed == null || parsed.pathSegments.isEmpty
              ? null : parsed.pathSegments.first;
          if (volume != null &&
              scannedVolumes.contains(volume) &&
              !availableMediaUris.contains(uri)) {
            removed++;
            continue;
          }
        }
      } catch (_) {
        // Preserve unknown entries rather than guessing their identity.
      }
      kept.add(raw);
    }
    if (removed != 0 && !await prefs.setStringList(storageKey, kept)) {
      throw StateError('Could not persist cleanup of stale Phone Recent URIs.');
    }
    return removed;
  }
}
