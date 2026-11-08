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
    String? entryName,
    List<int> pdfBytes = const [37, 80, 68, 70, 45, 49, 46, 52],
    bool includePdf = true,
    bool corruptMetadataHash = false,
    List<Map<String, Object?>> documents = const [
      {'id': 'doc-1', 'name': 'Policy'},
    ],
  }) async {
    final archive = Archive();
    final resolvedEntryName = entryName ??
        "pdfs/${DocumentToolsService.safeRestorePathToken('doc-1')}.pdf";
    final tableRows = <String, List<Map<String, Object?>>>{ 
      'folders': [],
      'documents': documents,
      'categories': [],
      'tags': [],
      'document_tags': [],
      'reminders': [],
      'history': [],
      'settings': [],
      'document_text_index': [],
    };
    final metadataFiles = <Map<String, Object?>>[];
    for (final entry in tableRows.entries) {
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(entry.value)));
      final name = '${entry.key}.json';
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
      metadataFiles.add({
        'entry': name,
        'sizeBytes': bytes.length,
        'sha256': corruptMetadataHash && entry.key == 'documents'
            ? List.filled(64, '0').join()
            : sha256.convert(bytes).toString(),
        'recordCount': entry.value.length,
      });
    }
    if (includePdf) {
      archive.addFile(ArchiveFile(resolvedEntryName, pdfBytes.length, Uint8List.fromList(pdfBytes)));
    }
    final manifest = {
      'format': 'DocsGridBackup',
      'version': 1,
      'metadataFiles': metadataFiles,
      'files': [
        {
          'documentId': 'doc-1',
          'entry': resolvedEntryName,
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

  test('accepts a complete backup with verified metadata and PDF', () async {
    final file = await writeArchive();
    expect(await DocumentToolsService().validateBackup(file), 1);
  });

  test('rejects modified metadata when its SHA-256 does not match', () async {
    final file = await writeArchive(corruptMetadataHash: true);
    await expectLater(DocumentToolsService().validateBackup(file), throwsStateError);
  });

  test('rejects archive paths that do not match the document ID', () async {
    final file = await writeArchive(entryName: '../../documents.json');
    await expectLater(DocumentToolsService().validateBackup(file), throwsStateError);
  });

  test('continues to accept legacy v1 PDF entry names', () async {
    final file = await writeArchive(entryName: 'pdfs/doc-1.pdf');
    expect(await DocumentToolsService().validateBackup(file), 1);
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
