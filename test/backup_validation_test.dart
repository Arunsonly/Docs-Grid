import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:docs_grid/features/tools/backup_archive_limits.dart';
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
    List<Map<String, Object?>> folders = const [],
    List<Map<String, Object?>> categories = const [],
    List<Map<String, Object?>> tags = const [],
    List<Map<String, Object?>> documentTags = const [],
    List<Map<String, Object?>> reminders = const [],
    List<Map<String, Object?>> history = const [],
    List<Map<String, Object?>> textIndexes = const [],
    List<Map<String, Object?>> settings = const [],
  }) async {
    final archive = Archive();
    final resolvedEntryName = entryName ??
        "pdfs/${DocumentToolsService.safeRestorePathToken('doc-1')}.pdf";
    final tableRows = <String, List<Map<String, Object?>>>{ 
      'folders': folders,
      'documents': documents,
      'categories': categories,
      'tags': tags,
      'document_tags': documentTags,
      'reminders': reminders,
      'history': history,
      'settings': settings,
      'document_text_index': textIndexes,
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

  test('rejects ZIP entries whose declared expansion exceeds the limit before decoding', () async {
    final archive = Archive()
      ..addFile(ArchiveFile('small.txt', 1, Uint8List.fromList([65])));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    final data = ByteData.sublistView(bytes);
    var centralOffset = -1;
    for (var offset = 0; offset <= bytes.length - 46; offset++) {
      if (data.getUint32(offset, Endian.little) == 0x02014b50) {
        centralOffset = offset;
        break;
      }
    }
    expect(centralOffset, greaterThanOrEqualTo(0));
    data.setUint32(
      centralOffset + 24,
      BackupArchiveLimits.maxEntryBytes + 1,
      Endian.little,
    );
    final file = File('${temp.path}/oversized.zip');
    await file.writeAsBytes(bytes, flush: true);
    await expectLater(BackupArchiveLimits.validate(file), throwsStateError);
  });

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

  test('rejects PDF bytes that disagree with document metadata', () async {
    final file = await writeArchive(documents: const [
      {'id': 'doc-1', 'name': 'Policy', 'sha256': '0000000000000000000000000000000000000000000000000000000000000000', 'size_bytes': 8},
    ]);
    await expectLater(DocumentToolsService().validateBackup(file), throwsStateError);
  });

  test('rejects PDF size that disagrees with document metadata', () async {
    final file = await writeArchive(documents: const [
      {'id': 'doc-1', 'name': 'Policy', 'size_bytes': 99},
    ]);
    await expectLater(DocumentToolsService().validateBackup(file), throwsStateError);
  });

  test('rejects duplicate document IDs in metadata', () async {
    final file = await writeArchive(documents: const [
      {'id': 'doc-1', 'name': 'Policy'},
      {'id': 'doc-1', 'name': 'Duplicate ID'},
    ]);
    await expectLater(DocumentToolsService().validateBackup(file), throwsStateError);
  });

  test('rejects folder names that could escape the private library path', () async {
    final file = await writeArchive(folders: const [
      {'id': 'folder-1', 'name': '../outside', 'parent_id': null},
    ]);
    await expectLater(DocumentToolsService().validateBackup(file), throwsStateError);
  });

  test('rejects Windows separators in archive metadata names', () async {
    final file = await writeArchive(documents: const [
      {'id': 'doc-1', 'name': r'..\outside'},
    ]);
    await expectLater(DocumentToolsService().validateBackup(file), throwsStateError);
  });

  test('rejects document names that could escape the library directory', () async {
    final file = await writeArchive(documents: const [
      {'id': 'doc-1', 'name': '../../outside'},
    ]);
    await expectLater(DocumentToolsService().validateBackup(file), throwsStateError);
  });

  test('rejects orphaned tag, reminder, history and OCR references', () async {
    final badTags = await writeArchive(
      tags: const [{'id': 'tag-1', 'name': 'Motor'}],
      documentTags: const [{'document_id': 'missing-doc', 'tag_id': 'tag-1'}],
    );
    await expectLater(DocumentToolsService().validateBackup(badTags), throwsFormatException);

    final badReminder = await writeArchive(
      reminders: const [{'id': 'reminder-1', 'document_id': 'missing-doc'}],
    );
    await expectLater(DocumentToolsService().validateBackup(badReminder), throwsFormatException);

    final badHistory = await writeArchive(
      history: const [{'id': 'history-1', 'document_id': 'missing-doc'}],
    );
    await expectLater(DocumentToolsService().validateBackup(badHistory), throwsFormatException);

    final badIndex = await writeArchive(
      textIndexes: const [{'document_id': 'missing-doc'}],
    );
    await expectLater(DocumentToolsService().validateBackup(badIndex), throwsFormatException);
  });

  test('rejects duplicate category and tag names before restore', () async {
    final duplicateCategories = await writeArchive(
      categories: const [
        {'id': 'cat-1', 'name': 'Insurance'},
        {'id': 'cat-2', 'name': 'insurance'},
      ],
    );
    await expectLater(
      DocumentToolsService().validateBackup(duplicateCategories),
      throwsFormatException,
    );

    final duplicateTags = await writeArchive(
      tags: const [
        {'id': 'tag-1', 'name': 'Motor'},
        {'id': 'tag-2', 'name': 'motor'},
      ],
    );
    await expectLater(
      DocumentToolsService().validateBackup(duplicateTags),
      throwsFormatException,
    );
  });

  test('rejects missing parents and cyclic folder graphs', () async {
    final missingParent = await writeArchive(folders: const [
      {'id': 'folder-1', 'name': 'Folder', 'parent_id': 'missing'},
    ]);
    await expectLater(DocumentToolsService().validateBackup(missingParent), throwsStateError);

    final cycle = await writeArchive(folders: const [
      {'id': 'folder-1', 'name': 'One', 'parent_id': 'folder-2'},
      {'id': 'folder-2', 'name': 'Two', 'parent_id': 'folder-1'},
    ]);
    await expectLater(DocumentToolsService().validateBackup(cycle), throwsStateError);
  });
}
