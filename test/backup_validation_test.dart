import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:docs_grid/features/tools/document_tools_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDirectory;
  late DocumentToolsService service;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('docsgrid-backup-test-');
    service = DocumentToolsService();
  });

  tearDown(() async {
    if (await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  Future<File> makeBackup({
    required List<Map<String, Object?>> documents,
    List<Map<String, Object?>> folders = const [],
    bool extraUnreferencedEntry = false,
  }) async {
    final archive = Archive();
    final tableNames = [
      'folders', 'documents', 'categories', 'tags', 'document_tags',
      'reminders', 'history', 'settings', 'document_text_index',
    ];
    final tableCounts = <String, int>{};
    for (final table in tableNames) {
      final rows = table == 'documents'
          ? documents
          : table == 'folders'
              ? folders
              : <Map<String, Object?>>[];
      final bytes = utf8.encode(jsonEncode(rows));
      tableCounts[table] = rows.length;
      archive.addFile(ArchiveFile('$table.json', bytes.length, bytes));
    }

    final fileRecords = <Map<String, Object?>>[];
    for (final id in ['doc-a', 'doc-b']) {
      final bytes = utf8.encode('%PDF-1.4\n$id\n%%EOF');
      archive.addFile(ArchiveFile('pdfs/$id.pdf', bytes.length, bytes));
      fileRecords.add({
        'documentId': id,
        'entry': 'pdfs/$id.pdf',
        'sha256': sha256.convert(bytes).toString(),
        'originalName': '$id.pdf',
      });
    }
    final manifest = {
      'format': 'DocsGridBackup',
      'version': 1,
      'createdAt': '2026-11-08T00:00:00.000Z',
      'tables': tableCounts,
      'files': fileRecords,
    };
    final manifestBytes = utf8.encode(jsonEncode(manifest));
    archive.addFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));
    if (extraUnreferencedEntry) {
      final extra = utf8.encode('unexpected');
      archive.addFile(ArchiveFile('unexpected.txt', extra.length, extra));
    }

    final file = File('${tempDirectory.path}/test-backup.zip');
    await file.writeAsBytes(ZipEncoder().encode(archive), flush: true);
    return file;
  }

  test('rejects unreferenced ZIP entries', () async {
    final file = await makeBackup(
      documents: [
        {'id': 'doc-a', 'name': 'A'},
        {'id': 'doc-b', 'name': 'B'},
      ],
      extraUnreferencedEntry: true,
    );

    await expectLater(
      service.validateBackup(file),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('unexpected'),
      )),
    );
  });

  test('accepts backup whose PDF and document metadata IDs match exactly', () async {
    final file = await makeBackup(documents: [
      {'id': 'doc-a', 'name': 'A'},
      {'id': 'doc-b', 'name': 'B'},
    ]);

    expect(await service.validateBackup(file), 2);
  });

  test('rejects duplicate document metadata IDs even when PDF IDs are unique', () async {
    final file = await makeBackup(documents: [
      {'id': 'doc-a', 'name': 'A'},
      {'id': 'doc-a', 'name': 'Duplicate A'},
    ]);

    await expectLater(
      service.validateBackup(file),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('duplicate document metadata'),
      )),
    );
  });

  test('rejects duplicate folder IDs during backup preflight', () async {
    final file = await makeBackup(
      documents: [
        {'id': 'doc-a', 'name': 'A'},
        {'id': 'doc-b', 'name': 'B'},
      ],
      folders: [
        {'id': 'folder-a', 'name': 'A', 'parent_id': null},
        {'id': 'folder-a', 'name': 'Duplicate', 'parent_id': null},
      ],
    );

    await expectLater(
      service.validateBackup(file),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('duplicate folder ID'),
      )),
    );
  });

  test('rejects missing parents and cyclic folder graphs before restore', () async {
    for (final folders in [
      [
        {'id': 'child', 'name': 'Child', 'parent_id': 'missing'},
      ],
      [
        {'id': 'a', 'name': 'A', 'parent_id': 'b'},
        {'id': 'b', 'name': 'B', 'parent_id': 'a'},
      ],
    ]) {
      final file = await makeBackup(
        documents: [
          {'id': 'doc-a', 'name': 'A'},
          {'id': 'doc-b', 'name': 'B'},
        ],
        folders: folders,
      );
      await expectLater(
        service.validateBackup(file),
        throwsA(isA<StateError>()),
      );
    }
  });

  test('rejects documents that reference missing folders before restore', () async {
    final file = await makeBackup(
      documents: [
        {'id': 'doc-a', 'name': 'A', 'folder_id': 'missing-folder'},
        {'id': 'doc-b', 'name': 'B'},
      ],
    );

    await expectLater(
      service.validateBackup(file),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('missing folder'),
      )),
    );
  });

  test('rejects a PDF whose document metadata row is missing', () async {
    final file = await makeBackup(documents: [
      {'id': 'doc-a', 'name': 'A'},
    ]);

    await expectLater(
      service.validateBackup(file),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('orphaned PDF entries'),
      )),
    );
  });
}
