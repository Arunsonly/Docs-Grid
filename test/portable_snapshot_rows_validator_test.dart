import 'package:docs_grid/features/tools/portable_snapshot_rows_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PortableSnapshotRowsValidator', () {
    test('accepts valid related snapshot rows', () {
      expect(
        () => PortableSnapshotRowsValidator.validate({
          'folders': [
            {'id': 'folder', 'parent_id': null},
          ],
          'categories': [
            {'id': 'category'},
          ],
          'tags': [
            {'id': 'tag'},
          ],
          'documents': [
            {'id': 'document', 'folder_id': 'folder', 'category_id': 'category'},
          ],
          'document_tags': [
            {'document_id': 'document', 'tag_id': 'tag'},
          ],
          'reminders': [
            {'id': 'reminder', 'document_id': 'document'},
          ],
          'history': [
            {'id': 'history', 'document_id': 'document'},
          ],
          'document_text_index': [
            {'document_id': 'document'},
          ],
        }),
        returnsNormally,
      );
    });

    test('rejects dangling document folder references', () {
      expect(
        () => PortableSnapshotRowsValidator.validate({
          'folders': <Map<String, Object?>>[],
          'documents': [
            {'id': 'document', 'folder_id': 'missing'},
          ],
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects dangling join-table references', () {
      expect(
        () => PortableSnapshotRowsValidator.validate({
          'documents': [
            {'id': 'document'},
          ],
          'tags': [
            {'id': 'tag'},
          ],
          'document_tags': [
            {'document_id': 'missing', 'tag_id': 'tag'},
          ],
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects duplicate IDs and duplicate OCR index records', () {
      expect(
        () => PortableSnapshotRowsValidator.validate({
          'documents': [
            {'id': 'same'},
            {'id': 'same'},
          ],
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => PortableSnapshotRowsValidator.validate({
          'documents': [
            {'id': 'document'},
          ],
          'document_text_index': [
            {'document_id': 'document'},
            {'document_id': 'document'},
          ],
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('requires non-null join and OCR references', () {
      expect(
        () => PortableSnapshotRowsValidator.validate({
          'documents': <Map<String, Object?>>[],
          'tags': <Map<String, Object?>>[],
          'document_tags': [
            {'document_id': null, 'tag_id': null},
          ],
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
