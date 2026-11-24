/// Presentation-only boundary between the managed Grid library and the
/// user's independently browsable Phone/Files locations.
///
/// Never delete, move or relink files here. A folder is excluded only when
/// its *location* matches the configured Grid root (or a known old Grid
/// root), not when it happens to share a PDF name or a category.
class GridStorageBoundary {
  GridStorageBoundary({String? activeRootUri})
      : _activeRoot = _normalize(activeRootUri ?? '');

  final String _activeRoot;

  static const _legacyRelativeRoots = <String>[
    'android/media/com.docsgrid.mobile',
    'android/media/com.docsgrid',
    'android/media/docsgrid',
  ];

  static String _normalize(String raw) {
    if (raw.isEmpty) return '';
    String decoded;
    try {
      decoded = Uri.decodeComponent(raw);
    } catch (_) {
      decoded = raw;
    }
    decoded = decoded.replaceAll('\\', '/').toLowerCase();
    // A file URI has a stable physical path; a SAF URI may have a
    // primary:Folder/Subfolder document ID instead.
    if (decoded.startsWith('file://')) {
      try {
        decoded = Uri.parse(raw).toFilePath().replaceAll('\\', '/').toLowerCase();
      } catch (_) {}
    }
    decoded = decoded.replaceAll(RegExp(r'/+'), '/');
    while (decoded.endsWith('/') && decoded.length > 1) {
      decoded = decoded.substring(0, decoded.length - 1);
    }
    return decoded;
  }

  static bool _atOrUnder(String candidate, String root) =>
      root.isNotEmpty && (candidate == root || candidate.startsWith('$root/'));

  static String _stripLabel(String path, String label) {
    if (label.isEmpty) return path;
    final prefix = _normalize(label);
    return _atOrUnder(path, prefix)
        ? (path == prefix ? '' : path.substring(prefix.length + 1))
        : path;
  }

  static String? _relativeToPrimary(String root) {
    for (final marker in [
      '/storage/emulated/0/',
      '/storage/self/primary/',
      '/mnt/sdcard/',
      '/primary:',
      'primary:',
    ]) {
      final index = root.indexOf(marker);
      if (index >= 0) {
        var value = root.substring(index + marker.length);
        // SAF tree IDs may be followed by another /document/ URI component.
        final end = value.indexOf('/document/');
        if (end >= 0) value = value.substring(0, end);
        return value;
      }
    }
    return null;
  }

  /// A configured Grid folder inside a Files/SAF browse root. The comparison
  /// requires a real parent-child relationship; unrelated "DocsGrid" folders
  /// elsewhere are not hidden simply because their name matches.
  String? _relativeToScanRoot(String scanRootUri) {
    if (_activeRoot.isEmpty) return null;
    final scan = _normalize(scanRootUri);
    if (scan.isEmpty) return null;
    if (_activeRoot == scan) return '';
    if (_activeRoot.startsWith('$scan/')) {
      return _activeRoot.substring(scan.length + 1);
    }
    // iOS/SAF providers can serialize the identical bookmark/URI with
    // different trailing document IDs. No guess: only resolved paths match.
    return null;
  }

  bool isManagedPath(String path, {
    String? scanRootUri,
    String rootLabel = '',
    String? volumeName,
  }) {
    final candidate = _normalize(path);
    if (candidate.isEmpty) return scanRootUri != null &&
        _activeRoot.isNotEmpty &&
        _normalize(scanRootUri) == _activeRoot;
    if (_atOrUnder(candidate, _activeRoot)) return true;

    // The old built-in Android managed paths remain protected during recovery
    // and when an updated app uses Internal Storage/DocsGrid instead.
    final relative = _stripLabel(candidate, rootLabel);
    final unlabelled = _stripLabel(relative, 'internal');
    for (final old in _legacyRelativeRoots) {
      if (_atOrUnder(candidate, old) ||
          _atOrUnder(relative, old) ||
          _atOrUnder(unlabelled, old) ||
          candidate.contains('/$old/')) return true;
    }

    if (scanRootUri != null) {
      final fromScan = _relativeToScanRoot(scanRootUri);
      if (fromScan != null) {
        return fromScan.isEmpty ||
            _atOrUnder(relative, fromScan) ||
            _atOrUnder(unlabelled, fromScan);
      }
    }

    final activePrimary = _relativeToPrimary(_activeRoot);
    if (activePrimary != null && activePrimary.isNotEmpty &&
        (volumeName == null || volumeName == 'external_primary')) {
      return _atOrUnder(relative, activePrimary) ||
          _atOrUnder(unlabelled, activePrimary);
    }
    return false;
  }

  bool isManagedEntry(Map<String, Object?> entry, {
    String? scanRootUri,
    String rootLabel = '',
  }) {
    final uri = entry['uri'];
    if (uri is String &&
        isManagedPath(uri, scanRootUri: null)) return true;
    final volume = entry['volumeName'] as String?;
    final path = entry['isDirectory'] == true
        ? (entry['path'] ?? entry['folderPath'])
        : (entry['folderPath'] ?? entry['path']);
    return path is String && isManagedPath(path,
        scanRootUri: scanRootUri, rootLabel: rootLabel,
        volumeName: volume);
  }

  List<Map<String, Object?>> filterEntries(
    Iterable<Map<String, Object?>> items, {
    String? scanRootUri,
    String rootLabel = '',
  }) => items.where((item) => !isManagedEntry(item,
      scanRootUri: scanRootUri, rootLabel: rootLabel)).toList(growable: false);
}
