import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The Phone Recent panel tracks external URI *references*, not file copies.
/// A successful Phone -> Grid move invalidates the source URI; never keep a
/// shortcut to an item which is now owned by the Grid library.
class PhoneRecentHistory {
  const PhoneRecentHistory._();

  static const storageKey = 'docsgrid_phone_recent_v1';
  static const observedFilesKey = 'docsgrid_phone_scanned_pdf_uris_v1';
  static Future<void> _operationsTail = Future<void>.value();

  // MediaStore notifications, Open, Move and Clear can arrive simultaneously.
  // Serialize preference read/modify/write to avoid undoing a recent action.
  static Future<T> _exclusive<T>(Future<T> Function() action) async {
    final previous = _operationsTail;
    final done = Completer<void>();
    _operationsTail = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
    }
  }


  /// Remember the result of a *completed* Phone storage scan. The first scan
  /// of each root/MediaStore volume establishes its baseline without treating
  /// thousands of existing PDFs as newly Added.
  ///
  /// On later completed scans, newly observed external PDF URIs are added to
  /// Phone Recent. Each independently verified scope is updated separately:
  /// a disconnected SD card, revoked SAF grant, or partial scan cannot erase
  /// its prior baseline or manufacture "new" entries after reconnection.
  ///
  /// The method never changes or deletes the physical PDF.
  static Future<int> observeCompletedScans(
    Map<String, List<Map<String, Object?>>> scannedScopes, {
    DateTime? observedAt,
  }) => _exclusive(() async {
    final prefs = await SharedPreferences.getInstance();
    return observeCompletedScansFromPreferences(
      prefs, scannedScopes, observedAt: observedAt,
    );
  });

  static Future<int> observeCompletedScansFromPreferences(
    SharedPreferences prefs,
    Map<String, List<Map<String, Object?>>> scannedScopes, {
    DateTime? observedAt,
  }) async {
    if (scannedScopes.isEmpty) return 0;
    final now = (observedAt ?? DateTime.now()).toUtc();
    final previous = <String, Set<String>>{};
    try {
      final raw = prefs.getString(observedFilesKey);
      final parsed = raw == null ? null : jsonDecode(raw);
      if (parsed is Map) {
        for (final entry in parsed.entries) {
          if (entry.key is String && entry.value is List) {
            previous[entry.key as String] =
                (entry.value as List).whereType<String>().toSet();
          }
        }
      }
    } catch (_) {
      // Damaged inventory is not proof that every file is new. Start a safe
      // baseline from the next completed scan instead of flooding Recent.
    }

    final next = <String, Set<String>>{
      for (final entry in previous.entries) entry.key: entry.value,
    };
    final discovered = <Map<String, Object?>>[];
    final discoveredUris = <String>{};

    for (final entry in scannedScopes.entries) {
      final scope = entry.key;
      if (!(scope.startsWith('media:') || scope.startsWith('root:'))) continue;
      final available = <String>{};
      final validFiles = <Map<String, Object?>>[];
      for (final file in entry.value) {
        if (file['isDirectory'] == true ||
            file['isInaccessible'] == true ||
            file['isInaccessibleSummary'] == true) continue;
        final uri = file['uri'];
        final name = file['name'];
        if (uri is! String || uri.isEmpty ||
            name is! String || !name.toLowerCase().endsWith('.pdf')) continue;
        // Grid, backups and DocsGrid recycle folders are not Phone PDFs.
        final location = (file['folderPath'] ?? file['path'] ?? '')
            .toString().replaceAll('\\', '/').toLowerCase();
        if (location.contains('android/media/com.docsgrid/') ||
            location.contains('android/media/docsgrid/')) continue;
        available.add(uri);
        validFiles.add(file);
      }

      final old = previous[scope];
      if (old != null) {
        for (final file in validFiles) {
          final uri = file['uri'] as String;
          if (!old.contains(uri) && discoveredUris.add(uri)) {
            discovered.add(file);
          }
        }
      }
      // A new scope is baseline-only; a previously seen scope accepts
      // removals so a later re-added PDF can be recognized as Added.
      next[scope] = available;
    }

    // Save the inventory even if no new file exists, so subsequent scans can
    // detect new PDFs. Limit the displayed Recent list, NOT the inventory.
    if (discovered.isNotEmpty) {
      discovered.sort((a, b) {
        final dateA = (a['lastModified'] as num?)?.toInt() ?? 0;
        final dateB = (b['lastModified'] as num?)?.toInt() ?? 0;
        return dateB.compareTo(dateA);
      });
      final previousRecent = prefs.getStringList(storageKey) ?? <String>[];
      final existingRecentUris = <String>{};
      for (final raw in previousRecent) {
        try {
          final value = jsonDecode(raw);
          if (value is Map && value['uri'] is String) {
            existingRecentUris.add(value['uri'] as String);
          }
        } catch (_) {
          // Preserve unknown historic entries, never classify them as PDFs.
        }
      }
      final added = <String>[];
      for (final file in discovered) {
        final uri = file['uri'] as String;
        if (existingRecentUris.add(uri)) {
          added.add(jsonEncode({
            'uri': uri,
            'name': file['name'],
            'sizeBytes': (file['sizeBytes'] as num?)?.toInt() ?? 0,
            if (file['folderPath'] is String)
              'folderPath': file['folderPath'],
            'addedAt': now.toIso8601String(),
          }));
        }
        if (added.length == 20) break;
      }
      if (added.isNotEmpty) {
        final nextRecent = [...added, ...previousRecent].take(20).toList();
        if (!await prefs.setStringList(storageKey, nextRecent)) {
          throw StateError('Could not save new Phone Recent PDF entries.');
        }
      }
    }
    final encoded = <String, List<String>>{
      for (final entry in next.entries)
        entry.key: entry.value.toList(growable: false)..sort(),
    };
    if (!await prefs.setString(observedFilesKey, jsonEncode(encoded))) {
      throw StateError('Could not save Phone storage scan baseline.');
    }
    return discovered.length;
  }

  /// An opened Phone PDF takes precedence over its earlier Added entry.
  /// Both actions identify the same URI, so Recent never duplicates a file.
  static Future<void> recordOpened(
    String uri,
    String name, {
    int sizeBytes = 0,
    String? folderPath,
    DateTime? openedAt,
  }) => _exclusive(() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(storageKey) ?? const <String>[];
    final kept = <String>[];
    Map<String, Object?>? prior;
    for (final raw in saved) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['uri'] == uri) {
          prior ??= Map<String, Object?>.from(decoded);
          continue;
        }
      } catch (_) {
        // Preserve older unknown entries.
      }
      kept.add(raw);
    }
    final active = <String, Object?>{
      ...?prior,
      'uri': uri,
      'name': name,
      'sizeBytes': sizeBytes > 0
          ? sizeBytes : (prior?['sizeBytes'] as num?)?.toInt() ?? 0,
      if (folderPath != null && folderPath.isNotEmpty)
        'folderPath': folderPath,
      'openedAt': (openedAt ?? DateTime.now()).toUtc().toIso8601String(),
    };
    if (!await prefs.setStringList(
        storageKey, [jsonEncode(active), ...kept].take(20).toList())) {
      throw StateError('Could not save the opened Phone PDF.');
    }
  });

  /// A rename changes the locator, not the logical user's Added/Opened time.
  /// Also change the scan baseline so a renamed item is not newly "Added".
  static Future<void> updateRenamedReference(
      String previousUri, String updatedUri, String updatedName) =>
      _exclusive(() async {
        final prefs = await SharedPreferences.getInstance();
        final old = prefs.getStringList(storageKey) ?? const <String>[];
        var changed = false;
        final next = <String>[];
        for (final raw in old) {
          try {
            final record = jsonDecode(raw);
            if (record is Map && record['uri'] == previousUri) {
              next.add(jsonEncode({
                ...Map<String, Object?>.from(record),
                'uri': updatedUri, 'name': updatedName,
              }));
              changed = true;
              continue;
            }
          } catch (_) { /* Preserve unknown records unchanged. */ }
          next.add(raw);
        }
        if (changed && !await prefs.setStringList(storageKey, next)) {
          throw StateError('Recent reference update was not persisted.');
        }
        final rawInventory = prefs.getString(observedFilesKey);
        if (rawInventory == null) return;
        final decoded = jsonDecode(rawInventory);
        if (decoded is! Map) return;
        var inventoryChanged = false;
        final updatedInventory = <String, List<String>>{};
        for (final entry in decoded.entries) {
          if (entry.key is! String || entry.value is! List) continue;
          final uriSet = (entry.value as List).whereType<String>().toSet();
          if (uriSet.remove(previousUri)) {
            uriSet.add(updatedUri);
            inventoryChanged = true;
          }
          updatedInventory[entry.key as String] = uriSet.toList()..sort();
        }
        if (inventoryChanged && !await prefs.setString(
            observedFilesKey, jsonEncode(updatedInventory))) {
          throw StateError('Scan baseline could not be updated after rename.');
        }
      });

  /// Clearing Recent is not clearing the scan inventory. Existing Phone PDFs
  /// must not all reappear as new on the next foreground scan.
  static Future<void> clearRecent() => _exclusive(() async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.remove(storageKey)) {
      throw StateError('Could not clear Phone Recent.');
    }
  });

  /// A move is considered complete only after the source was deleted by the
  /// storage provider. Remove that *exact* URI without disturbing any other
  /// recent items, including entries in older or unknown formats.
  static Future<bool> removeMovedSource(String uri) async {
    if (uri.isEmpty) return false;
    return _exclusive(() async {
      final prefs = await SharedPreferences.getInstance();
      return removeMovedSourceFromPreferences(prefs, uri);
    });
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
    return _exclusive(() async {
      final prefs = await SharedPreferences.getInstance();
      return pruneAbsentMediaStoreUrisFromPreferences(
          prefs, availableMediaUris, scannedVolumes: scannedVolumes);
    });
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
