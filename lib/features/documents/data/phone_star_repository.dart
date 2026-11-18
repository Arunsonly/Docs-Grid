import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Stars on Phone PDFs are URI references, not imported Grid document copies.
/// Changing Star cannot move, delete, or otherwise alter a source file.
class PhoneStarRepository {
  PhoneStarRepository._();

  static const storageKey = 'docsgrid_phone_starred_pdfs_v1';
  static Future<void> _tail = Future<void>.value();

  static Future<T> _exclusive<T>(Future<T> Function() action) async {
    final previous = _tail;
    final completer = Completer<void>();
    _tail = completer.future;
    await previous;
    try {
      return await action();
    } finally {
      completer.complete();
    }
  }

  static Future<List<Map<String, Object?>>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final items = <Map<String, Object?>>[];
    for (final raw in prefs.getStringList(storageKey) ?? const <String>[]) {
      try {
        final item = jsonDecode(raw);
        if (item is Map && item['uri'] is String && item['name'] is String) {
          items.add(Map<String, Object?>.from(item));
        }
      } catch (_) {
        // Malformed optional metadata cannot prevent the Starred view opening.
      }
    }
    return items;
  }

  /// Returns true if the PDF was added, false if an existing star was removed.
  static Future<bool> toggle({
    required String uri,
    required String name,
    String? folderPath,
    int sizeBytes = 0,
  }) => _exclusive(() async {
    if (uri.isEmpty) throw ArgumentError('PDF URI must not be empty.');
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(storageKey) ?? <String>[];
    final kept = <String>[];
    var wasStarred = false;
    for (final raw in saved) {
      try {
        final parsed = jsonDecode(raw);
        if (parsed is Map && parsed['uri'] == uri) {
          wasStarred = true;
          continue;
        }
      } catch (_) {}
      kept.add(raw);
    }
    if (!wasStarred) {
      kept.insert(0, jsonEncode({
        'uri': uri,
        'name': name,
        'folderPath': folderPath ?? '',
        'sizeBytes': sizeBytes,
        'starredAt': DateTime.now().toUtc().toIso8601String(),
      }));
    }
    if (!await prefs.setStringList(storageKey, kept)) {
      throw StateError('Could not save Phone Star preference.');
    }
    return !wasStarred;
  });

  /// Clean only a successfully deleted/moved source reference.
  static Future<void> remove(String uri) => _exclusive(() async {
    if (uri.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(storageKey) ?? const <String>[];
    final kept = <String>[];
    for (final raw in saved) {
      try {
        final value = jsonDecode(raw);
        if (value is Map && value['uri'] == uri) continue;
      } catch (_) {}
      kept.add(raw);
    }
    if (kept.length != saved.length &&
        !await prefs.setStringList(storageKey, kept)) {
      throw StateError('Could not remove stale Phone Star.');
    }
  });
}
