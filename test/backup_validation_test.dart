import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:docs_grid/features/tools/document_tools_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('docsgrid-backup-test-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<File> writeArchive({
    String entryName = 'pdfs/doc-1.pdf',
    List<int> pdfBytes = const [37, 80, 68, 70, 45, 49, 46, 52],
    bool includePdf = true,
    List<Map<String, Object?>> documents = const [
      {'id': 'doc-1', 'name': 'Policy'},
    ],
  }) async {
    final archive = Archive();
    final documentBytes = utf8.encode(jsonEncode(documents));
    archive.addFile(ArchiveFile('documents.json', documentBytes.length, documentBytes));
    if (includePdf) {
      archive.addFile(ArchiveFile(entryName, pdfBytes.length, Uint8List.fromList(pdfBytes)));
    }
    final manifest = {
      'format': 'DocsGridBackup',
      'version': 1,
      'files': [
        {
          'documentId': 'doc-1',
          'entry': entryName,
          'sha256': sha256.convert(pdfBytes).toString(),
        },
      ],
    };
    final manifestBytes = utf8.encode(jsonEncode(manifest));
    archive.addFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));
    final bytes = ZipEncoder().encode(archive);
    final file = File('${temp.path}/backup.zip');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  test('accepts a complete backup with a PDF signature and matching hash', () async {
    final file = await writeArchive();
    expect(await DocumentToolsService().validateBackup(file), 1);
  });

  test('rejects archive paths that do not match the document ID', () async {
    final file = await writeArchive(entryName: '../../documents.json');
    await expectLater(DocumentToolsService().validateBackup(file), throwsStateError);
  });

  test('rejects non-PDF content even when its hash matches the manifest', () async {
    final file = await writeArchive(pdfBytes: utf8.encode('not a PDF'));
    await expectLater(DocumentToolsService().validateBackup(file), throwsStateError);
  });

  test('rejects a backup missing one or more document PDFs', () async {
    final file = await writeArchive(includePdf: false);
    await expectLater(DocumentToolsService().validateBackup(file), throwsStateError);
  });

  test('rejects duplicate document IDs in metadata', () async {
    final file = await writeArchive(documents: const [
      {'id': 'doc-1', 'name': 'Policy'},
      {'id': 'doc-1', 'name': 'Duplicate ID'},
    ]);
    await expectLater(DocumentToolsService().validateBackup(file), throwsStateError);
  });
}
