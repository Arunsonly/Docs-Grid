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
    for (final entry in tables.entries) {
      if (!seen.contains('${entry.key}.json')) {
        throw FormatException('Snapshot is missing metadata for ${entry.key}.');
      }
      final file = files.firstWhere((item) => item.path == '${entry.key}.json');
      if (file.recordCount != entry.value) {
        throw FormatException('Snapshot table count does not match ${entry.key}.json.');
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

  /// Validates folder identifiers, path components and the complete parent graph
  /// before restore code creates any provider directories.
  static Map<String, Map<String, Object?>> validateFolderRows(
    List<Map<String, Object?>> rows,
  ) {
    final byId = <String, Map<String, Object?>>{};
    for (final row in rows) {
      final id = row['id'];
      final name = row['name'];
      final parentId = row['parent_id'];
      if (id is! String || id.trim().isEmpty || id != id.trim() ||
          byId.containsKey(id)) {
        throw const FormatException('Snapshot contains an invalid or duplicate folder ID.');
      }
      if (name is! String || name.trim().isEmpty || name != name.trim() ||
          name == '.' || name == '..' || name.contains('/') ||
          name.contains(String.fromCharCode(92)) || name.contains(String.fromCharCode(0)) ||
          name.length > 255 ||
          name.codeUnits.any((unit) => unit < 32 || unit == 127)) {
        throw const FormatException('Snapshot contains an unsafe folder name.');
      }
      if (parentId != null &&
          (parentId is! String || parentId.trim().isEmpty || parentId != parentId.trim())) {
        throw const FormatException('Snapshot contains an invalid folder parent reference.');
      }
      byId[id] = row;
    }

    final siblingNames = <String>{};
    for (final row in byId.values) {
      final parentId = row['parent_id'] as String?;
      if (parentId != null && !byId.containsKey(parentId)) {
        throw const FormatException('Snapshot references a missing parent folder.');
      }
      final name = (row['name'] as String).toLowerCase();
      final siblingKey = '${parentId ?? '<root>'}\\u0000$name';
      if (!siblingNames.add(siblingKey)) {
        throw const FormatException('Snapshot contains duplicate sibling folder names.');
      }
    }

    // Walk parent chains iteratively: a valid but deeply nested user folder
    // tree must not overflow the Dart call stack during restore validation.
    final visited = <String>{};
    for (final id in byId.keys) {
      final path = <String>{};
      String? current = id;
      while (current != null && !visited.contains(current)) {
        if (!path.add(current)) {
          throw const FormatException('Snapshot folder hierarchy contains a cycle.');
        }
        current = byId[current]!['parent_id'] as String?;
      }
      visited.addAll(path);
    }
    return Map.unmodifiable(byId);
  }


  /// Checks cross-table references before restore touches the selected library
  /// or begins a database transaction.
  static void validateRelations(
    Map<String, List<Map<String, Object?>>> tables,
  ) {
    Set<String> ids(String table) {
      final result = <String>{};
      for (final row in tables[table] ?? const []) {
        final value = row['id'];
        if (value is! String || value.trim().isEmpty || !result.add(value)) {
          throw FormatException('Snapshot contains an invalid or duplicate $table ID.');
        }
      }
      return result;
    }

    final folderIds = ids('folders');
    final documentIds = ids('documents');
    final categoryIds = ids('categories');
    final tagIds = ids('tags');
    ids('reminders');
    ids('history');

    for (final table in ['categories', 'tags']) {
      final names = <String>{};
      for (final row in tables[table] ?? const []) {
        final name = row['name'];
        if (name is! String || name.trim().isEmpty ||
            !names.add(name.toLowerCase())) {
          throw FormatException('Snapshot contains an invalid or duplicate $table name.');
        }
      }
    }

    for (final row in tables['documents'] ?? const []) {
      final folderId = row['folder_id'];
      if (folderId != null && (folderId is! String || !folderIds.contains(folderId))) {
        throw const FormatException('Snapshot document references a missing folder.');
      }
      final categoryId = row['category_id'];
      if (categoryId != null && (categoryId is! String || !categoryIds.contains(categoryId))) {
        throw const FormatException('Snapshot document references a missing category.');
      }
    }

    final documentTagPairs = <String>{};
    for (final row in tables['document_tags'] ?? const []) {
      final documentId = row['document_id'];
      final tagId = row['tag_id'];
      if (documentId is! String || !documentIds.contains(documentId) ||
          tagId is! String || !tagIds.contains(tagId)) {
        throw const FormatException('Snapshot document tag references a missing record.');
      }
      if (!documentTagPairs.add('$documentId\\u0000$tagId')) {
        throw const FormatException('Snapshot contains a duplicate document tag relation.');
      }
    }

    for (final table in ['reminders', 'history', 'document_text_index']) {
      for (final row in tables[table] ?? const []) {
        final documentId = row['document_id'];
        if (documentId != null &&
            (documentId is! String || !documentIds.contains(documentId))) {
          throw FormatException('Snapshot $table record references a missing document.');
        }
      }
    }

    final indexedDocuments = <String>{};
    for (final row in tables['document_text_index'] ?? const []) {
      final documentId = row['document_id'];
      if (documentId is! String || !indexedDocuments.add(documentId)) {
        throw const FormatException('Snapshot contains duplicate document text indexes.');
      }
    }

    final settingKeys = <String>{};
    for (final row in tables['settings'] ?? const []) {
      final key = row['key'];
      if (key is! String || key.trim().isEmpty || !settingKeys.add(key)) {
        throw const FormatException('Snapshot contains an invalid or duplicate setting key.');
      }
    }
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
