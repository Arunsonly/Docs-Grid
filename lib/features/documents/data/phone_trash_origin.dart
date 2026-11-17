import 'dart:io';

import 'package:path/path.dart' as p;

/// Exact Phone Storage provenance for a verified PDF archived in DocsGrid's
/// Recycle Bin. Never infer a writable target from a deleted MediaStore URI.
class PhoneTrashOrigin {
  const PhoneTrashOrigin({
    required this.sourceUri,
    required this.folderPath,
    required this.rootUri,
    required this.displayName,
    this.volumeName,
  });

  static const metadataKey = 'phoneTrashOrigin';

  final String sourceUri;
  /// Phone browser folder label, e.g. Internal/Download or Granted folder 1/X.
  final String folderPath;
  /// Actual Android-granted file volume or SAF root captured before deleting.
  final String rootUri;
  final String displayName;
  final String? volumeName;

  Map<String, Object?> toJson() => {
    'sourceUri': sourceUri,
    'folderPath': folderPath,
    'rootUri': rootUri,
    'displayName': displayName,
    if (volumeName != null) 'volumeName': volumeName,
  };

  static PhoneTrashOrigin? fromMetadata(Map<String, Object?> metadata) {
    final raw = metadata[metadataKey];
    if (raw is! Map) return null;
    final source = raw['sourceUri'], folder = raw['folderPath'];
    final root = raw['rootUri'], name = raw['displayName'];
    if (source is! String || source.isEmpty ||
        folder is! String || folder.isEmpty ||
        root is! String || root.isEmpty ||
        name is! String || name.isEmpty) return null;
    return PhoneTrashOrigin(
      sourceUri: source, folderPath: folder,
      rootUri: root, displayName: name,
      volumeName: raw['volumeName'] is String ? raw['volumeName'] as String : null,
    );
  }

  /// A permitted scope is required *before* archiving: otherwise the original
  /// cannot be restored reliably, and the Phone PDF must not be deleted.
  static String? selectGrantedRoot({
    required String sourceUri,
    required String folderPath,
    required Iterable<Map<String, String>> roots,
    String? volumeName,
  }) {
    final source = Uri.tryParse(sourceUri);
    if (source == null) return null;
    final granted = roots.where((r) => r['uri']?.isNotEmpty == true).toList();

    if (source.scheme == 'file') {
      final sourcePath = p.normalize(source.toFilePath());
      final eligible = granted.where((r) {
        final root = Uri.tryParse(r['uri']!);
        if (root?.scheme != 'file') return false;
        final rootPath = p.normalize(root!.toFilePath());
        return p.isWithin(rootPath, sourcePath);
      }).toList()
        ..sort((a, b) => b['uri']!.length.compareTo(a['uri']!.length));
      return eligible.isEmpty ? null : eligible.first['uri'];
    }

    if (source.authority == 'media' && source.scheme == 'content') {
      // MediaStore's synthetic display label may differ from the Android root
      // order. Prefer its authoritative volume name, not "External storage 1".
      if (volumeName == null || volumeName.isEmpty) return null;
      for (final root in granted) {
        final u = Uri.tryParse(root['uri']!);
        if (u?.scheme != 'file') continue;
        if (volumeName == 'external_primary' &&
            (root['name'] ?? '').toLowerCase().startsWith('internal')) {
          return root['uri'];
        }
        if (volumeName != 'external_primary' &&
            p.basename(p.normalize(u!.toFilePath())).toLowerCase() ==
                volumeName.toLowerCase()) {
          return root['uri'];
        }
      }
      return null;
    }

    // SAF grants are opaque. Only a root with the SAME provider and tree ID
    // is safe to use. A same-looking folder name does not establish access.
    if (source.scheme == 'content') {
      final sourceParts = source.pathSegments;
      final treeAt = sourceParts.indexOf('tree');
      if (treeAt < 0 || treeAt + 1 >= sourceParts.length) return null;
      final treeId = sourceParts[treeAt + 1];
      for (final root in granted) {
        final u = Uri.tryParse(root['uri']!);
        if (u == null || u.scheme != 'content' ||
            u.authority != source.authority) continue;
        final rootParts = u.pathSegments;
        final rootTreeAt = rootParts.indexOf('tree');
        if (rootTreeAt >= 0 && rootTreeAt + 1 < rootParts.length &&
            rootParts[rootTreeAt + 1] == treeId) {
          return root['uri'];
        }
      }
    }
    return null;
  }

  /// Resolve ONLY root-relative folder segments from a recorded scanner
  /// label. Refuse traversal and malformed input; never write outside a grant.
  List<String> get relativeFolders {
    final normalized = folderPath.replaceAll('\\', '/');
    final segments = normalized.split('/');
    if (segments.isEmpty || segments.first.isEmpty ||
        !isRootLabel(segments.first)) {
      throw StateError('Original Phone folder label is unavailable.');
    }
    final result = segments.skip(1).toList();
    if (result.any((s) => s.isEmpty || s == '.' || s == '..' ||
        s.contains('\u0000') || s.contains('\\'))) {
      throw StateError('Original Phone folder path is unsafe.');
    }
    return result;
  }

  static bool isRootLabel(String label) {
    final value = label.toLowerCase();
    return value == 'internal' || value == 'internal storage' ||
        value.startsWith('external storage ') ||
        value.startsWith('granted folder ');
  }

  String get folderName => folderPath.replaceAll('\\', '/').split('/').last;

  /// For a local source URI, also verify the recorded folder hierarchy.
  /// A forged label may not cause restoration into a different physical path.
  bool localSourceMatchesRoot() {
    final source = Uri.tryParse(sourceUri);
    final root = Uri.tryParse(rootUri);
    if (source?.scheme != 'file' || root?.scheme != 'file') return true;
    final expected = p.normalize(p.joinAll([
      root!.toFilePath(), ...relativeFolders,
    ]));
    return p.normalize(p.dirname(source!.toFilePath())) == expected;
  }

  /// The original URI's old ID can be invalid after recycle, so it must not
  /// be used as a destination for restored bytes.
  bool get hasWritableOrigin => rootUri.startsWith('file://') ||
      rootUri.startsWith('content://');
}
