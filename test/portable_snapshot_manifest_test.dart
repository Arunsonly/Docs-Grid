import 'dart:convert';

import 'package:docs_grid/features/tools/portable_snapshot_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _manifest(int schemaVersion) => {
  'format': 'DocsGridPortableData',
  'formatVersion': 1,
  'snapshotId': 'snapshot-test',
  'databaseSchemaVersion': schemaVersion,
  'tables': {'folders': 0, 'documents': 0},
  'files': [
    {
      'path': 'folders.json',
      'sizeBytes': 2,
      'sha256': List.filled(64, 'a').join(),
      'recordCount': 0,
    },
    {
      'path': 'documents.json',
      'sizeBytes': 2,
      'sha256': List.filled(64, 'b').join(),
      'recordCount': 0,
    },
  ],
};

void main() {
  test('portable snapshot parser accepts current schema v7', () {
    final parsed = PortableSnapshotManifest.parse(
      jsonEncode(_manifest(7)),
    );
    expect(parsed.databaseSchemaVersion, 7);
  });

  test('portable snapshot parser rejects a newer schema', () {
    expect(
      () => PortableSnapshotManifest.parse(jsonEncode(_manifest(8))),
      throwsA(isA<FormatException>()),
    );
  });

  test('portable snapshots include durable tables but exclude derived tables', () {
    expect(
      PortableSnapshotManifest.supportedTableNames,
      containsAll(['folders', 'documents', 'document_text_index', 'schema_migrations']),
    );
    expect(PortableSnapshotManifest.supportedTableNames, isNot(contains('documents_name_fts')));
    expect(PortableSnapshotManifest.supportedTableNames, isNot(contains('document_summary_state')));
  });
}
