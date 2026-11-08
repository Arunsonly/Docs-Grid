/// Validates untrusted portable snapshot rows before storage or database writes.
class PortableSnapshotRowsValidator {
  const PortableSnapshotRowsValidator._();

  static void validate(Map<String, List<Map<String, Object?>>> tables) {
    final folderIds = _ids(tables, 'folders');
    final documentIds = _ids(tables, 'documents');
    final categoryIds = _ids(tables, 'categories');
    final tagIds = _ids(tables, 'tags');
    _ids(tables, 'reminders');
    _ids(tables, 'history');

    void requiredString(String table, String field, {bool nonEmpty = true}) {
      for (final row in tables[table] ?? const <Map<String, Object?>>[]) {
        final value = row[field];
        if (value is! String || (nonEmpty && value.trim().isEmpty)) {
          throw FormatException('Snapshot contains an invalid $table.$field value.');
        }
      }
    }

    void optionalString(String table, String field) {
      for (final row in tables[table] ?? const <Map<String, Object?>>[]) {
        if (row[field] != null && row[field] is! String) {
          throw FormatException('Snapshot contains an invalid $table.$field value.');
        }
      }
    }

    void optionalInt(String table, String field, {int? min}) {\n      for (final row in tables[table] ?? const <Map<String, Object?>>[]) {\n        final value = row[field];\n        if (value != null && (value is! int || (min != null && value < min))) {\n          throw FormatException('Snapshot contains an invalid $table.$field value.');\n        }\n      }\n    }\n\n    void requiredInt(String table, String field, {int? min}) {
      for (final row in tables[table] ?? const <Map<String, Object?>>[]) {
        final value = row[field];
        if (value is! int || (min != null && value < min)) {
          throw FormatException('Snapshot contains an invalid $table.$field value.');
        }
      }
    }

    void optionalReference(String table, String field, Set<String> allowed,
        {bool nullable = true}) {
      for (final row in tables[table] ?? const <Map<String, Object?>>[]) {
        final value = row[field];
        if (value == null && nullable) continue;
        if (value is! String || !allowed.contains(value)) {
          throw FormatException('Snapshot contains an invalid $table.$field reference.');
        }
      }
    }

    void uniqueText(String table, String field, {bool caseInsensitive = false}) {
      final seen = <String>{};
      for (final row in tables[table] ?? const <Map<String, Object?>>[]) {
        final value = row[field];
        if (value is! String || value.trim().isEmpty) {
          throw FormatException('Snapshot contains an invalid $table.$field value.');
        }
        final key = caseInsensitive ? value.toLowerCase() : value;
        if (!seen.add(key)) {
          throw FormatException('Snapshot contains duplicate $table.$field values.');
        }
      }
    }

    // Required SQLite columns and nullable column types. Validate before the
    // restore creates any directories so malformed rows cannot leave debris.
    for (final field in ['name', 'created_at', 'updated_at']) {
      if (field == 'updated_at') {
        // folders and documents have updated_at; the other tables do not.
        requiredString('folders', field);
        requiredString('documents', field);
      } else {
        requiredString('folders', field);
        requiredString('categories', field);
        requiredString('tags', field);
      }
    }
    requiredString('documents', 'name');
    requiredString('documents', 'mime_type');
    requiredString('documents', 'created_at');
    requiredString('documents', 'updated_at');
    requiredString('categories', 'name');
    requiredString('categories', 'created_at');
    requiredString('tags', 'name');
    requiredString('tags', 'created_at');
    requiredString('reminders', 'title');
    requiredString('reminders', 'remind_at_utc');
    requiredString('reminders', 'timezone_id');
    requiredString('reminders', 'next_fire_at_utc');
    requiredString('reminders', 'created_at');
    requiredString('reminders', 'updated_at');
    requiredString('history', 'action');
    requiredString('history', 'created_at');
    requiredString('settings', 'key');
    requiredString('settings', 'value_json', nonEmpty: false);
    requiredString('settings', 'updated_at');
    requiredString('document_text_index', 'extracted_text', nonEmpty: false);
    requiredString('document_text_index', 'indexed_at');
    requiredInt('documents', 'size_bytes', min: 0);
    requiredInt('reminders', 'enabled', min: 0);
    requiredInt('document_text_index', 'page_count', min: 0);

    for (final field in ['original_name', 'storage_uri', 'relative_path', 'sha256',
      'expiry_date', 'last_opened_at', 'deleted_at', 'source', 'metadata_json']) {
      optionalString('documents', field);
    }
    optionalString('folders', 'storage_uri_or_relative_path');
    optionalString('folders', 'deleted_at');
    optionalString('reminders', 'note');
    optionalString('reminders', 'recurrence_rule');
    optionalString('reminders', 'recurrence_end_at');
    optionalInt('reminders', 'lead_days');\n    optionalInt('reminders', 'notification_id');\n    requiredInt('categories', 'is_builtin', min: 0);
    optionalString('reminders', 'snoozed_until');
    optionalString('reminders', 'completed_at');
    optionalString('history', 'details_json');

    optionalReference('folders', 'parent_id', folderIds);
    optionalReference('documents', 'folder_id', folderIds);
    optionalReference('documents', 'category_id', categoryIds);
    optionalReference('document_tags', 'document_id', documentIds, nullable: false);
    optionalReference('document_tags', 'tag_id', tagIds, nullable: false);
    optionalReference('reminders', 'document_id', documentIds);
    optionalReference('history', 'document_id', documentIds);
    optionalReference('document_text_index', 'document_id', documentIds, nullable: false);

    uniqueText('categories', 'name', caseInsensitive: true);
    uniqueText('tags', 'name', caseInsensitive: true);
    uniqueText('settings', 'key');

    final pairs = <String>{};
    for (final row in tables['document_tags'] ?? const <Map<String, Object?>>[]) {
      final key = '${row['document_id']}\u0000${row['tag_id']}';
      if (!pairs.add(key)) {
        throw const FormatException('Snapshot contains duplicate document-tag links.');
      }
    }

    final indexedDocuments = <String>{};
    for (final row in tables['document_text_index'] ?? const <Map<String, Object?>>[]) {
      final id = row['document_id'] as String;
      if (!indexedDocuments.add(id)) {
        throw const FormatException('Snapshot contains duplicate document text indexes.');
      }
    }
  }

  static Set<String> _ids(
      Map<String, List<Map<String, Object?>>> tables, String table) {
    final seen = <String>{};
    for (final row in tables[table] ?? const <Map<String, Object?>>[]) {
      final id = row['id'];
      if (id is! String || id.trim().isEmpty || !seen.add(id)) {
        throw FormatException('Snapshot contains an invalid or duplicate $table ID.');
      }
    }
    return seen;
  }
}
