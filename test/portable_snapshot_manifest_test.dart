import 'dart:convert';

import 'package:docs_grid/features/tools/portable_snapshot_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, Object?> validManifest() => {
    'format': 'DocsGridPortableData',
    'formatVersion': 1,
    'snapshotId': 'snapshot-test-1',
    'databaseSchemaVersion': 3,
    'tables': {'documents': 1, 'folders': 0, 'tags': 2},
    'files': [
      {'path': 'documents.json', 'sizeBytes': 2, 'sha256': List.filled(64, 'a').join(), 'recordCount': 1},
      {'path': 'folders.json', 'sizeBytes': 2, 'sha256': List.filled(64, 'b').join(), 'recordCount': 0},
      {'path': 'tags.json', 'sizeBytes': 2, 'sha256': List.filled(64, 'c').join(), 'recordCount': 2},
    ],
  };

  test('parses a complete version 1 snapshot manifest', () {
    final manifest = PortableSnapshotManifest.parse(jsonEncode(validManifest()));

    expect(manifest.snapshotId, 'snapshot-test-1');
    expect(manifest.databaseSchemaVersion, 3);
    expect(manifest.tables['tags'], 2);
    expect(manifest.files.map((file) => file.path),
      ['documents.json', 'folders.json', 'tags.json']);
  });

  test('rejects unsupported snapshot versions', () {
    final value = validManifest()..['formatVersion'] = 99;
    expect(() => PortableSnapshotManifest.parse(jsonEncode(value)),
      throwsFormatException);
  });

  test('rejects path traversal and nested file paths', () {
    final value = validManifest();
    (value['files'] as List).first['path'] = '../documents.json';
    expect(() => PortableSnapshotManifest.parse(jsonEncode(value)),
      throwsFormatException);
  });

  test('rejects duplicate metadata filenames', () {
    final value = validManifest();
    final files = value['files'] as List<dynamic>;
    files.add(Map<String, Object>.from(files.first as Map));
    expect(() => PortableSnapshotManifest.parse(jsonEncode(value)),
      throwsFormatException);
  });

  test('rejects invalid hashes and missing required tables', () {
    final badHash = validManifest();
    (badHash['files'] as List).first['sha256'] = 'not-a-hash';
    expect(() => PortableSnapshotManifest.parse(jsonEncode(badHash)),
      throwsFormatException);

    final missing = validManifest()..['tables'] = {'tags': 2};
    expect(() => PortableSnapshotManifest.parse(jsonEncode(missing)),
      throwsFormatException);
  });

  group('portable snapshot folder graph', () {
    test('accepts a valid nested folder graph', () {
      final result = PortableSnapshotManifest.validateFolderRows([
        {'id': 'root', 'name': 'Policies', 'parent_id': null},
        {'id': 'child', 'name': 'Motor', 'parent_id': 'root'},
      ]);
      expect(result.keys, containsAll(['root', 'child']));
    });

    test('rejects duplicate IDs and missing parents', () {
      expect(
        () => PortableSnapshotManifest.validateFolderRows([
          {'id': 'same', 'name': 'A', 'parent_id': null},
          {'id': 'same', 'name': 'B', 'parent_id': null},
        ]),
        throwsFormatException,
      );
      expect(
        () => PortableSnapshotManifest.validateFolderRows([
          {'id': 'child', 'name': 'Child', 'parent_id': 'missing'},
        ]),
        throwsFormatException,
      );
    });

    test('rejects duplicate sibling names case-insensitively', () {
      expect(
        () => PortableSnapshotManifest.validateFolderRows([
          {'id': 'one', 'name': 'Policies', 'parent_id': null},
          {'id': 'two', 'name': 'policies', 'parent_id': null},
        ]),
        throwsFormatException,
      );
      expect(
        () => PortableSnapshotManifest.validateFolderRows([
          {'id': 'root-a', 'name': 'A', 'parent_id': null},
          {'id': 'root-b', 'name': 'B', 'parent_id': null},
          {'id': 'child-a', 'name': 'Policy', 'parent_id': 'root-a'},
          {'id': 'child-b', 'name': 'policy', 'parent_id': 'root-b'},
        ]),
        returnsNormally,
      );
    });

    test('rejects cycles and unsafe path components', () {
      expect(
        () => PortableSnapshotManifest.validateFolderRows([
          {'id': 'a', 'name': 'A', 'parent_id': 'b'},
          {'id': 'b', 'name': 'B', 'parent_id': 'a'},
        ]),
        throwsFormatException,
      );
      for (final unsafe in ['.', '..', 'a/b', 'a${String.fromCharCode(92)}b', 'bad\u0000name']) {
        expect(
          () => PortableSnapshotManifest.validateFolderRows([
            {'id': 'x', 'name': unsafe, 'parent_id': null},
          ]),
          throwsFormatException,
          reason: 'Unsafe folder name should be rejected: $unsafe',
        );
      }
    });

    test('handles a deep hierarchy iteratively without recursion overflow', () {
      final rows = List.generate(1500, (index) => {
        'id': 'folder-$index',
        'name': 'Folder $index',
        'parent_id': index == 0 ? null : 'folder-${index - 1}',
      });
      expect(
        PortableSnapshotManifest.validateFolderRows(rows),
        hasLength(1500),
      );
    });
  });

  group('portable snapshot relational integrity', () {
    Map<String, List<Map<String, Object?>>> validRows() => {
      'folders': [{'id': 'folder-1', 'name': 'Policies', 'parent_id': null}],
      'categories': [{'id': 'category-1', 'name': 'Insurance'}],
      'tags': [{'id': 'tag-1', 'name': 'Motor'}],
      'documents': [{
        'id': 'document-1',
        'folder_id': 'folder-1',
        'category_id': 'category-1',
      }],
      'document_tags': [{'document_id': 'document-1', 'tag_id': 'tag-1'}],
      'reminders': [{'id': 'reminder-1', 'document_id': 'document-1'}],
      'history': [{'id': 'history-1', 'document_id': 'document-1'}],
      'document_text_index': [{'document_id': 'document-1'}],
      'settings': [{'key': 'sort_order'}],
    };

    test('accepts valid foreign-key relationships', () {
      expect(
        () => PortableSnapshotManifest.validateRelations(validRows()),
        returnsNormally,
      );
    });

    test('rejects documents with missing folder or category', () {
      final missingFolder = validRows();
      missingFolder['documents']!.first['folder_id'] = 'missing';
      expect(
        () => PortableSnapshotManifest.validateRelations(missingFolder),
        throwsFormatException,
      );

      final missingCategory = validRows();
      missingCategory['documents']!.first['category_id'] = 'missing';
      expect(
        () => PortableSnapshotManifest.validateRelations(missingCategory),
        throwsFormatException,
      );
    });

    test('rejects orphaned tags, reminders, history and OCR rows', () {
      for (final table in ['document_tags', 'reminders', 'history', 'document_text_index']) {
        final rows = validRows();
        if (table == 'document_tags') {
          rows[table]!.first['document_id'] = 'missing';
        } else {
          rows[table]!.first['document_id'] = 'missing';
        }
        expect(
          () => PortableSnapshotManifest.validateRelations(rows),
          throwsFormatException,
          reason: '$table must not reference a missing document',
        );
      }

      final missingTag = validRows();
      missingTag['document_tags']!.first['tag_id'] = 'missing';
      expect(
        () => PortableSnapshotManifest.validateRelations(missingTag),
        throwsFormatException,
      );
    });

    test('rejects duplicate IDs, relations, indexes and setting keys', () {
      final duplicateDocument = validRows();
      duplicateDocument['documents']!.add(Map<String, Object?>.from(
        duplicateDocument['documents']!.first,
      ));
      expect(
        () => PortableSnapshotManifest.validateRelations(duplicateDocument),
        throwsFormatException,
      );

      final duplicateRelation = validRows();
      duplicateRelation['document_tags']!.add(
        Map<String, Object?>.from(duplicateRelation['document_tags']!.first),
      );
      expect(
        () => PortableSnapshotManifest.validateRelations(duplicateRelation),
        throwsFormatException,
      );

      final duplicateIndex = validRows();
      duplicateIndex['document_text_index']!.add(
        Map<String, Object?>.from(duplicateIndex['document_text_index']!.first),
      );
      expect(
        () => PortableSnapshotManifest.validateRelations(duplicateIndex),
        throwsFormatException,
      );

      final duplicateSetting = validRows();
      duplicateSetting['settings']!.add({'key': 'sort_order'});
      expect(
        () => PortableSnapshotManifest.validateRelations(duplicateSetting),
        throwsFormatException,
      );
    });
  });

  test('rejects a table count that differs from its metadata file record count', () {
    final value = validManifest();
    (value['files'] as List).first['recordCount'] = 9;
    expect(() => PortableSnapshotManifest.parse(jsonEncode(value)),
      throwsFormatException);
  });

  test('rejects a table without its matching JSON file', () {
    final value = validManifest();
    (value['files'] as List).removeLast();
    expect(() => PortableSnapshotManifest.parse(jsonEncode(value)),
      throwsFormatException);
  });
}
