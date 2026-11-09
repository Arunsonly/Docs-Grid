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

    test('rejects cycles and unsafe path components', () {
      expect(
        () => PortableSnapshotManifest.validateFolderRows([
          {'id': 'a', 'name': 'A', 'parent_id': 'b'},
          {'id': 'b', 'name': 'B', 'parent_id': 'a'},
        ]),
        throwsFormatException,
      );
      for (final unsafe in ['.', '..', 'a/b', r'a\\b', 'bad\u0000name']) {
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
