import 'dart:convert';

/// Strict, side-effect-free validation for portable DocsGrid snapshot manifests.
/// File contents are verified separately before any restore operation.
class PortableSnapshotManifest {
  PortableSnapshotManifest._({
    required this.snapshotId,
    required this.formatVersion,
    required this.databaseSchemaVersion,
    required this.files,
    required this.tables,
  });

  final String snapshotId;
  final int formatVersion;
  final int databaseSchemaVersion;
  final List<PortableSnapshotFile> files;
  final Map<String, int> tables;

  static PortableSnapshotManifest parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Snapshot manifest must be a JSON object.');
    }
    if (decoded['format'] != 'DocsGridPortableData' ||
        decoded['formatVersion'] != 1) {
      throw const FormatException('Unsupported DocsGrid portable snapshot format.');
    }
    final snapshotId = decoded['snapshotId'];
    final schemaVersion = decoded['databaseSchemaVersion'];
    final rawFiles = decoded['files'];
    final rawTables = decoded['tables'];
    if (snapshotId is! String || snapshotId.trim().isEmpty ||
        schemaVersion is! int || schemaVersion < 1 ||
        rawFiles is! List || rawTables is! Map) {
      throw const FormatException('Snapshot manifest is missing required fields.');
    }

    final tables = <String, int>{};
    for (final entry in rawTables.entries) {
      if (entry.key is! String || entry.value is! int || entry.value < 0) {
        throw const FormatException('Snapshot table counts are invalid.');
      }
      tables[entry.key as String] = entry.value as int;
    }
    if (!tables.containsKey('documents') || !tables.containsKey('folders')) {
      throw const FormatException('Snapshot does not contain required document and folder tables.');
    }

    final files = <PortableSnapshotFile>[];
    final seen = <String>{};
    for (final raw in rawFiles) {
      if (raw is! Map) {
        throw const FormatException('Snapshot file record is invalid.');
      }
      final path = raw['path'];
      final size = raw['sizeBytes'];
      final digest = raw['sha256'];
      final count = raw['recordCount'];
      if (path is! String || path.isEmpty ||
          path == '.' || path == '..' ||
          path.contains('/') || path.contains('\\') ||
          path.contains(':') || path.contains('\u0000') ||
          size is! int || size < 0 ||
          digest is! String || !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(digest) ||
          count is! int || count < 0 ||
          !path.endsWith('.json') || !seen.add(path)) {
        throw const FormatException('Snapshot contains an unsafe or invalid metadata file record.');
      }
      files.add(PortableSnapshotFile(
        path: path,
        sizeBytes: size,
        sha256: digest.toLowerCase(),
        recordCount: count,
      ));
    }
    for (final table in tables.keys) {
      if (!seen.contains('$table.json')) {
        throw FormatException('Snapshot is missing metadata for $table.');
      }
    }
    return PortableSnapshotManifest._(
      snapshotId: snapshotId,
      formatVersion: 1,
      databaseSchemaVersion: schemaVersion,
      files: List.unmodifiable(files),
      tables: Map.unmodifiable(tables),
    );
  }
}

class PortableSnapshotFile {
  const PortableSnapshotFile({
    required this.path,
    required this.sizeBytes,
    required this.sha256,
    required this.recordCount,
  });

  final String path;
  final int sizeBytes;
  final String sha256;
  final int recordCount;
}
