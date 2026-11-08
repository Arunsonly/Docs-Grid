/// Validates cross-table references in untrusted portable snapshots before
/// the restore process touches the user's selected storage.
class PortableSnapshotRowsValidator {
  const PortableSnapshotRowsValidator._();

  static void validate(Map<String, List<Map<String, Object?>>> tables) {
    Set<String> ids(String table) {
      final seen = <String>{};
      for (final row in tables[table] ?? const <Map<String, Object?>>[]) {
        final id = row['id'];
        if (id is! String || id.trim().isEmpty || !seen.add(id)) {
          throw FormatException('Snapshot contains an invalid or duplicate $table ID.');
        }
      }
      return seen;
    }

    final folderIds = ids('folders');
    final documentIds = ids('documents');
    final categoryIds = ids('categories');
    final tagIds = ids('tags');
    ids('reminders');
    ids('history');

    void optionalReference(
      String table,
      String field,
      Set<String> allowed, {
      bool nullable = true,
    }) {
      for (final row in tables[table] ?? const <Map<String, Object?>>[]) {
        final value = row[field];
        if (value == null && nullable) continue;
        if (value is! String || !allowed.contains(value)) {
          throw FormatException('Snapshot contains an invalid $table.$field reference.');
        }
      }
    }

    optionalReference('folders', 'parent_id', folderIds);
    optionalReference('documents', 'folder_id', folderIds);
    optionalReference('documents', 'category_id', categoryIds);
    optionalReference('document_tags', 'document_id', documentIds, nullable: false);
    optionalReference('document_tags', 'tag_id', tagIds, nullable: false);
    optionalReference('reminders', 'document_id', documentIds);
    optionalReference('history', 'document_id', documentIds);
    optionalReference('document_text_index', 'document_id', documentIds, nullable: false);

    final indexedDocuments = <String>{};
    for (final row in tables['document_text_index'] ?? const <Map<String, Object?>>[]) {
      final id = row['document_id'] as String;
      if (!indexedDocuments.add(id)) {
        throw const FormatException('Snapshot contains duplicate document text indexes.');
      }
    }
  }
}
