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
    (value['files'] as List).add(
      Map<String, Object?>.from((value['files'] as List).first as Map),
    );
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

  test('rejects a table without its matching JSON file', () {
    final value = validManifest();
    (value['files'] as List).removeLast();
    expect(() => PortableSnapshotManifest.parse(jsonEncode(value)),
      throwsFormatException);
  });
}
