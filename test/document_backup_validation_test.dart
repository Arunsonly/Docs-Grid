import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:docs_grid/features/tools/document_tools_service.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, List<Map<String, Object?>>> _validRows({bool databaseOnly = false}) => {
  'folders': <Map<String, Object?>>[],
  'categories': <Map<String, Object?>>[],
  'tags': <Map<String, Object?>>[],
  'documents': [{
    'id': 'document-1', 'name': 'Policy', 'original_name': null,
    'storage_uri': databaseOnly ? 'missing://document-1' : '/unused/policy.pdf', 'relative_path': null,
    'mime_type': 'application/pdf', 'size_bytes': 12, 'sha256': null,
    'folder_id': null, 'category_id': null, 'extracted_text_status': 'pending',
    'expiry_date': null, 'created_at': '2026-01-01T00:00:00Z',
    'updated_at': '2026-01-01T00:00:00Z', 'last_opened_at': null,
    'deleted_at': null, 'source': null, 'metadata_json': null,
  }],
  'document_tags': <Map<String, Object?>>[],
  'reminders': <Map<String, Object?>>[],
  'history': <Map<String, Object?>>[],
  'settings': <Map<String, Object?>>[],
  'document_text_index': <Map<String, Object?>>[],
};

Future<File> _makeBackup(
  Directory directory, {
  String entry = 'pdfs/policy.pdf',
  List<int>? pdfBytes,
  String? shaOverride,
  bool includeFileRecord = true,
  bool databaseOnly = false,
  bool corruptMetadataChecksum = false,
}) async {
  final bytes = pdfBytes ?? utf8.encode('%PDF-1.7\nDocsGrid test PDF');
  final archive = Archive();
  final metadataFiles = <Map<String, Object?>>[];
  for (final table in _validRows(databaseOnly: databaseOnly).entries) {
    final json = Uint8List.fromList(utf8.encode(jsonEncode(table.value)));
    archive.addFile(ArchiveFile('${table.key}.json', json.length, json));
    metadataFiles.add({
      'entry': '${table.key}.json',
      'sizeBytes': json.length,
      'sha256': corruptMetadataChecksum
          ? List.filled(64, '0').join()
          : sha256.convert(json).toString(),
    });
  }
  if (!databaseOnly) {
    archive.addFile(ArchiveFile(entry, bytes.length, Uint8List.fromList(bytes)));
  }
  final manifest = <String, Object?>{
    'format': 'DocsGridBackup',
    'version': 1,
    if (databaseOnly) 'backupType': 'database',
    'createdAt': '2026-01-01T00:00:00Z',
    'tables': <String, int>{
      for (final table in _validRows().entries) table.key: table.value.length,
    },
    'metadataFiles': metadataFiles,
    'files': includeFileRecord && !databaseOnly ? [{
      'documentId': 'document-1',
      'entry': entry,
      'sha256': shaOverride ?? sha256.convert(bytes).toString(),
      'originalName': 'Policy.pdf',
    }] : <Map<String, Object?>>[],
  };
  final manifestBytes = Uint8List.fromList(utf8.encode(jsonEncode(manifest)));
  archive.addFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));
  final zipBytes = ZipEncoder().encode(archive);
  final file = File('${directory.path}/test_backup.zip');
  await file.writeAsBytes(zipBytes, flush: true);
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  final service = DocumentToolsService();

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('docsgrid_backup_test_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('accepts a valid backup and verifies its PDF payload', () async {
    final file = await _makeBackup(temp);
    expect(await service.validateBackup(file), 1);
  });

  test(
    'restore confirmation receives the validated count and cancel skips restore',
    () async {
    final file = await _makeBackup(temp);
    int? confirmedCount;

    final restored = await service.restoreBackup(
      file,
      confirm: (count) async {
        confirmedCount = count;
        return false;
      },
    );

      expect(confirmedCount, 1);
      expect(restored, isNull);
    },
  );

  test('rejects metadata JSON whose manifest checksum does not match', () async {
    final file = await _makeBackup(temp, corruptMetadataChecksum: true);
    await expectLater(service.validateBackup(file), throwsA(isA<StateError>()));
  });

  test('accepts database-only backup with document metadata and no PDF payload', () async {
    final file = await _makeBackup(temp, databaseOnly: true);
    expect(await service.validateBackup(file), 0);
  });

  test('rejects unsafe archive paths before extracting any file', () async {
    final file = await _makeBackup(temp, entry: 'pdfs/../escape.pdf');
    await expectLater(service.validateBackup(file), throwsA(isA<StateError>()));
  });

  test('rejects a payload that is not a PDF even when its hash matches', () async {
    final file = await _makeBackup(temp, pdfBytes: utf8.encode('not a PDF'));
    await expectLater(service.validateBackup(file), throwsA(isA<StateError>()));
  });

  test('rejects a PDF whose manifest SHA-256 does not match', () async {
    final file = await _makeBackup(temp, shaOverride: List.filled(64, '0').join());
    await expectLater(service.validateBackup(file), throwsA(isA<StateError>()));
  });

  test('rejects a backup missing the one-to-one PDF record', () async {
    final file = await _makeBackup(temp, includeFileRecord: false);
    await expectLater(service.validateBackup(file), throwsA(isA<StateError>()));
  });
}
