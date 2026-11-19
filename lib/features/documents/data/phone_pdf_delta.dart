/// Applies validated, narrowly scoped MediaStore changes to the last complete
/// Phone index. Unrelated SAF/cloud entries and metadata are never discarded.
class PhonePdfDelta {
  PhonePdfDelta._();

  /// MediaStore rows carry a volumeName. Other provider rows must not be
  /// removed merely because a local filename happens to match.
  static String? _localPathKey(Map<String, Object?> item) {
    if (item['volumeName'] != 'external_primary' ||
        item['isDirectory'] == true) return null;
    final name = item['name'];
    if (name is! String || name.isEmpty) return null;
    final folder = item['folderPath'] as String? ?? '';
    return '${folder.isEmpty ? 'Internal' : folder}/$name'.toLowerCase();
  }

  static bool _sameRow(Map<String, Object?> a, Map<String, Object?> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  static PhonePdfDeltaResult apply({
    required List<Map<String, Object?>> existing,
    required List<Map<String, Object?>> updates,
    required Iterable<String> touchedMediaUris,
    required Iterable<String> touchedLocalPaths,
  }) {
    final uris = touchedMediaUris.toSet();
    final paths = touchedLocalPaths.map((s) => s.toLowerCase()).toSet();
    final updatedByUri = <String, Map<String, Object?>>{};
    for (final item in updates) {
      final uri = item['uri'];
      if (uri is! String || uri.isEmpty || item['isDirectory'] == true) {
        continue;
      }
      updatedByUri[uri] = item;
    }
    final merged = <Map<String, Object?>>[];
    final seen = <String>{};
    var changed = false;
    for (final old in existing) {
      final uri = old['uri'] as String?;
      final oldPath = _localPathKey(old);
      final matches = (uri != null && uris.contains(uri)) ||
          (oldPath != null && paths.contains(oldPath)) ||
          (uri != null && updatedByUri.containsKey(uri));
      if (!matches) {
        merged.add(old);
        if (uri != null) seen.add(uri);
        continue;
      }
      final next = uri == null ? null : updatedByUri[uri];
      if (next == null) {
        changed = true;
        continue;
      }
      if (!seen.add(uri!)) {
        changed = true;
        continue;
      }
      if (_sameRow(old, next)) {
        merged.add(old); // Preserve unchanged object/widget identity.
      } else {
        merged.add(next);
        changed = true;
      }
    }
    for (final next in updatedByUri.values) {
      final uri = next['uri'] as String;
      if (seen.add(uri)) {
        merged.add(next);
        changed = true;
      }
    }
    return PhonePdfDeltaResult(
      entries: changed ? List<Map<String, Object?>>.unmodifiable(merged) : existing,
      changed: changed,
    );
  }
}

class PhonePdfDeltaResult {
  const PhonePdfDeltaResult({required this.entries, required this.changed});
  final List<Map<String, Object?>> entries;
  final bool changed;
}
