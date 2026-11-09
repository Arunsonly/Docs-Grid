import 'package:docs_grid/features/tools/portable_snapshot_rows_validator.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, List<Map<String, Object?>>> validSnapshot() => {
  'folders': [{'id': 'folder', 'name': 'Folder', 'parent_id': null,
    'storage_uri_or_relative_path': null, 'created_at': '2026-01-01T00:00:00Z',
    'updated_at': '2026-01-01T00:00:00Z', 'deleted_at': null}],
  'categories': [{'id': 'category', 'name': 'Category', 'icon_key': null,
    'color_key': null, 'is_builtin': 0, 'created_at': '2026-01-01T00:00:00Z'}],
  'tags': [{'id': 'tag', 'name': 'Tag', 'created_at': '2026-01-01T00:00:00Z'}],
  'documents': [{'id': 'document', 'name': 'Document', 'original_name': null,
    'storage_uri': null, 'relative_path': null, 'mime_type': 'application/pdf',
    'size_bytes': 10, 'sha256': null, 'folder_id': 'folder',
    'category_id': 'category', 'extracted_text_status': 'pending',
    'expiry_date': null, 'created_at': '2026-01-01T00:00:00Z',
    'updated_at': '2026-01-01T00:00:00Z', 'last_opened_at': null,
    'deleted_at': null, 'source': null, 'metadata_json': null}],
  'document_tags': [{'document_id': 'document', 'tag_id': 'tag'}],
  'reminders': [{'id': 'reminder', 'document_id': 'document', 'title': 'Reminder',
    'note': null, 'remind_at_utc': '2026-01-02T00:00:00Z',
    'timezone_id': 'UTC', 'recurrence_rule': null, 'recurrence_end_at': null,
    'lead_days': null, 'enabled': 1, 'status': 'scheduled',
    'snoozed_until': null, 'next_fire_at_utc': '2026-01-02T00:00:00Z',
    'notification_id': null, 'created_at': '2026-01-01T00:00:00Z',
    'updated_at': '2026-01-01T00:00:00Z', 'completed_at': null}],
  'history': [{'id': 'history', 'document_id': 'document', 'action': 'imported',
    'details_json': null, 'created_at': '2026-01-01T00:00:00Z'}],
  'settings': [{'key': 'theme', 'value_json': '"dark"',
    'updated_at': '2026-01-01T00:00:00Z'}],
  'document_text_index': [{'document_id': 'document', 'extracted_text': 'text',
    'indexed_at': '2026-01-01T00:00:00Z', 'page_count': 1}],
};

void main() {
  group('PortableSnapshotRowsValidator', () {
    test('accepts valid related snapshot rows', () {
      expect(() => PortableSnapshotRowsValidator.validate(validSnapshot()), returnsNormally);
    });

    test('rejects dangling folder and join-table references', () {
      final folder = validSnapshot()..['documents']![0]['folder_id'] = 'missing';
      expect(() => PortableSnapshotRowsValidator.validate(folder), throwsA(isA<FormatException>()));

      final link = validSnapshot()..['document_tags']![0]['document_id'] = 'missing';
      expect(() => PortableSnapshotRowsValidator.validate(link), throwsA(isA<FormatException>()));
    });

    test('rejects duplicate IDs and duplicate OCR index records', () {
      final duplicate = validSnapshot();
      duplicate['documents']!.add(Map<String, Object?>.from(duplicate['documents']!.first));
      expect(() => PortableSnapshotRowsValidator.validate(duplicate), throwsA(isA<FormatException>()));

      final duplicateIndex = validSnapshot();
      duplicateIndex['document_text_index']!.add(
        Map<String, Object?>.from(duplicateIndex['document_text_index']!.first));
      expect(() => PortableSnapshotRowsValidator.validate(duplicateIndex), throwsA(isA<FormatException>()));
    });

    test('rejects invalid required field types before restore writes', () {
      final invalid = validSnapshot();
      invalid['documents']![0]['size_bytes'] = -1;
      expect(() => PortableSnapshotRowsValidator.validate(invalid), throwsA(isA<FormatException>()));

      final invalidReminder = validSnapshot();
      invalidReminder['reminders']![0]['enabled'] = 'yes';
      expect(() => PortableSnapshotRowsValidator.validate(invalidReminder), throwsA(isA<FormatException>()));
    });

    test('rejects duplicate category/tag names and duplicate join links', () {
      final duplicateCategory = validSnapshot();
      duplicateCategory['categories']!.add({
        ...duplicateCategory['categories']!.first, 'id': 'category-2',
        'name': 'cATEGORY',
      });
      expect(() => PortableSnapshotRowsValidator.validate(duplicateCategory), throwsA(isA<FormatException>()));

      final duplicateLink = validSnapshot();
      duplicateLink['document_tags']!.add(Map<String, Object?>.from(duplicateLink['document_tags']!.first));
      expect(() => PortableSnapshotRowsValidator.validate(duplicateLink), throwsA(isA<FormatException>()));
    });

    test('requires non-null join and OCR references', () {
      final invalidLink = validSnapshot();
      invalidLink['document_tags']![0]['document_id'] = null;
      expect(() => PortableSnapshotRowsValidator.validate(invalidLink), throwsA(isA<FormatException>()));

      final invalidIndex = validSnapshot();
      invalidIndex['document_text_index']![0]['document_id'] = null;
      expect(() => PortableSnapshotRowsValidator.validate(invalidIndex), throwsA(isA<FormatException>()));
    });
  });
}
