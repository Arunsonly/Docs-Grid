import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Phone PDFs are external references, not Grid-owned byte copies.
/// A logical ID must survive in-app rename even when the provider URI changes.
class PhoneReferenceIdentity {
  PhoneReferenceIdentity._();
  static const storageKey = 'docsgrid_phone_reference_ids_v1';
  static const _uuid = Uuid();
  static Future<void> _tail = Future<void>.value();

  static Future<T> _serialized<T>(Future<T> Function() task) async {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    await previous;
    try {
      return await task();
    } finally {
      done.complete();
    }
  }

  static Map<String, String> _parse(String? value) {
    if (value == null) return <String, String>{};
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return <String, String>{};
      return {
        for (final row in decoded.entries)
          if (row.key is String && row.value is String)
            row.key as String: row.value as String,
      };
    } catch (_) {
      return <String, String>{};
    }
  }

  static Future<String> idForUri(String uri) => _serialized(() async {
    if (uri.isEmpty) throw ArgumentError('Phone URI is required');
    final prefs = await SharedPreferences.getInstance();
    final current = _parse(prefs.getString(storageKey));
    final known = current[uri];
    if (known != null) return known;
    final id = _uuid.v4();
    current[uri] = id;
    if (!await prefs.setString(storageKey, jsonEncode(current))) {
      throw StateError('Could not persist Phone reference identity');
    }
    return id;
  });

  /// A manual file selection may bind an imported logical ID only if the
  /// selected storage locator does not belong to another live reference.
  static Future<void> bindSelected(String uri, String referenceId) =>
      _serialized(() async {
    if (uri.isEmpty || referenceId.isEmpty) {
      throw ArgumentError('A valid Phone file and identity are required');
    }
    final prefs = await SharedPreferences.getInstance();
    final current = _parse(prefs.getString(storageKey));
    final existing = current[uri];
    if (existing != null && existing != referenceId) {
      throw StateError('This Phone PDF already belongs to another reference');
    }
    current[uri] = referenceId;
    if (!await prefs.setString(storageKey, jsonEncode(current))) {
      throw StateError('Could not bind the selected Phone PDF');
    }
  });

  static Future<void> renamed(String oldUri, String newUri) =>
      _serialized(() async {
    if (oldUri == newUri) return;
    if (oldUri.isEmpty || newUri.isEmpty) {
      throw ArgumentError('A rename needs both storage locators');
    }
    final prefs = await SharedPreferences.getInstance();
    final current = _parse(prefs.getString(storageKey));
    final previous = current[oldUri];
    if (previous == null) return;
    final conflicting = current[newUri];
    if (conflicting != null && conflicting != previous) {
      throw StateError('The new PDF location has another document identity');
    }
    current.remove(oldUri);
    current[newUri] = previous;
    if (!await prefs.setString(storageKey, jsonEncode(current))) {
      throw StateError('Could not update Phone reference identity');
    }
  });
}

/// A versioned, portable snapshot of user choices (never of phone PDF bytes).
/// Imported URIs have no transferred permission; restore as relink-needed
/// references, not as working shortcuts to the old device.
class PhonePortableState {
  PhonePortableState._();
  static const format = 'DocsGridPhoneReferences';
  static const version = 1;
  static const pendingKey = 'docsgrid_phone_relink_pending_v1';
  static const starKey = 'docsgrid_phone_starred_pdfs_v1';
  static const recentKey = 'docsgrid_phone_recent_v1';
  static const phoneSortKey = 'docsgrid_phone_sort_preference_v1';
  static const gridSortKey = 'docsgrid_grid_sort_preference_v1';

  static List<Map<String, Object?>> _readRecords(List<String>? raw) {
    final records = <Map<String, Object?>>[];
    for (final text in raw ?? const <String>[]) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map && decoded['uri'] is String &&
            decoded['name'] is String) {
          records.add(Map<String, Object?>.from(decoded));
        }
      } catch (_) {
        // Do not destroy unrecognized developer preferences.
      }
    }
    return records;
  }

  static Future<Map<String, Object?>> capture() async {
    final prefs = await SharedPreferences.getInstance();

    Future<List<Map<String, Object?>>> withIds(String key) async {
      final records = _readRecords(prefs.getStringList(key));
      var updated = false;
      for (final record in records) {
        final id = await PhoneReferenceIdentity.idForUri(record['uri'] as String);
        if (record['referenceId'] != id) {
          record['referenceId'] = id;
          updated = true;
        }
      }
      if (updated &&
          !await prefs.setStringList(key, records.map(jsonEncode).toList())) {
        throw StateError('Could not persist Phone logical references');
      }
      return records;
    }

    return <String, Object?>{
      'format': format, 'version': version,
      'stars': await withIds(starKey),
      'recent': await withIds(recentKey),
      if (prefs.getString(phoneSortKey) != null)
        'phoneSort': prefs.getString(phoneSortKey),
      if (prefs.getString(gridSortKey) != null)
        'gridSort': prefs.getString(gridSortKey),
    };
  }

  static Map<String, Object?> validate(Object? source) {
    if (source is! Map || source['format'] != format ||
        source['version'] != version) {
      throw FormatException('Unsupported Phone reference backup');
    }
    final result = <String, Object?>{'format': format, 'version': version};
    for (final field in ['stars', 'recent']) {
      final rows = source[field];
      if (rows is! List || rows.length > 10000) {
        throw FormatException('Invalid Phone reference count');
      }
      final accepted = <Map<String, Object?>>[];
      final seen = <String>{};
      for (final raw in rows) {
        if (raw is! Map || raw['uri'] is! String ||
            raw['name'] is! String || raw['referenceId'] is! String ||
            (raw['uri'] as String).length > 4096 ||
            (raw['name'] as String).length > 1024 ||
            !seen.add(raw['referenceId'] as String)) {
          throw FormatException('Invalid or duplicate Phone document reference');
        }
        accepted.add(Map<String, Object?>.from(raw));
      }
      result[field] = accepted;
    }
    for (final key in ['phoneSort', 'gridSort']) {
      final raw = source[key];
      if (raw is String && raw.length <= 2048) {
        final decoded = jsonDecode(raw);
        if (decoded is! Map ||
            !['name', 'date'].contains(decoded['field']) ||
            decoded['ascending'] is! bool ||
            decoded['explicit'] is! bool) {
          throw FormatException('Invalid Phone sorting metadata');
        }
        result[key] = raw;
      }
    }
    return result;
  }

  static Future<void> restoreAsPending(Map<String, Object?> source) async {
    final saved = validate(source);
    final prefs = await SharedPreferences.getInstance();
    final existing = _readRecords(prefs.getStringList(pendingKey));
    final byId = <String, Map<String, Object?>>{
      for (final row in existing)
        if (row['referenceId'] is String)
          row['referenceId'] as String: row,
    };
    final stars = (saved['stars'] as List).cast<Map<String, Object?>>();
    final recent = (saved['recent'] as List).cast<Map<String, Object?>>();
    final staged = <String, Map<String, Object?>>{};
    for (final record in [...stars, ...recent]) {
      final id = record['referenceId'] as String;
      final entry = staged.putIfAbsent(id, () => {
        ...record,
        'originalUri': record['uri'],
        'uri': 'missing://phone-reference/$id',
        'needsRelinking': true,
        'wasStarred': false,
        'wasRecent': false,
      });
      if (stars.any((s) => s['referenceId'] == id)) entry['wasStarred'] = true;
      if (recent.any((s) => s['referenceId'] == id)) entry['wasRecent'] = true;
    }
    final liveIds = <String>{
      for (final entry in [
        ..._readRecords(prefs.getStringList(starKey)),
        ..._readRecords(prefs.getStringList(recentKey)),
      ])
        if (entry['referenceId'] is String)
          entry['referenceId'] as String,
    };
    for (final entry in staged.entries) {
      if (!liveIds.contains(entry.key)) byId.putIfAbsent(entry.key, () => entry.value);
    }
    if (!await prefs.setStringList(
        pendingKey, byId.values.map(jsonEncode).toList())) {
      throw StateError('Phone references could not be staged for relinking');
    }
    for (final key in ['phoneSort', 'gridSort']) {
      final actualKey = key == 'phoneSort' ? phoneSortKey : gridSortKey;
      final value = saved[key];
      if (value is String && prefs.getString(actualKey) == null &&
          !await prefs.setString(actualKey, value)) {
        throw StateError('Phone sorting choice could not be restored');
      }
    }
  }

  /// Manual relinking is the only authority for reusing an imported
  /// reference on another phone. The caller must first verify that the
  /// selected URI is currently readable through the storage provider.
  static Future<void> relink({
    required String referenceId,
    required String selectedUri,
    required String selectedName,
  }) async {
    if (referenceId.isEmpty || selectedUri.isEmpty || selectedName.isEmpty ||
        !selectedName.toLowerCase().endsWith('.pdf')) {
      throw ArgumentError('Choose a readable PDF to relink');
    }
    final prefs = await SharedPreferences.getInstance();
    final entries = _readRecords(prefs.getStringList(pendingKey));
    final matching = entries.where((e) => e['referenceId'] == referenceId);
    if (matching.length != 1) {
      throw StateError('The backed-up Phone reference is no longer pending');
    }
    final original = matching.single;
    await PhoneReferenceIdentity.bindSelected(selectedUri, referenceId);
    final restored = <String, Object?>{
      ...original,
      'uri': selectedUri,
      'name': selectedName,
      'needsRelinking': false,
    }..remove('originalUri');

    Future<void> writeIfSelected(String key, bool include) async {
      if (!include) return;
      final current = _readRecords(prefs.getStringList(key));
      if (current.any((e) => e['referenceId'] == referenceId)) return;
      if (current.any((e) => e['uri'] == selectedUri)) {
        throw StateError('Selected PDF already has a separate Phone reference');
      }
      current.insert(0, restored);
      if (!await prefs.setStringList(key,
          (key == recentKey ? current.take(20) : current).map(jsonEncode).toList())) {
        throw StateError('Could not restore the selected Phone reference');
      }
    }

    await writeIfSelected(starKey, original['wasStarred'] == true);
    await writeIfSelected(recentKey, original['wasRecent'] == true);
    final remaining = entries.where((e) => e['referenceId'] != referenceId).toList();
    if (!await prefs.setStringList(
        pendingKey, remaining.map(jsonEncode).toList())) {
      throw StateError('Could not complete Phone reference relinking');
    }
  }

  static Future<List<Map<String, Object?>>> pending() async {
    final prefs = await SharedPreferences.getInstance();
    return _readRecords(prefs.getStringList(pendingKey));
  }
}
