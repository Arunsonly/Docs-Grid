import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:docs_grid/features/tools/backup_chain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

List<int> pdfBytes(String id) => utf8.encode('%PDF-1.7\nDocsGrid ' + id);
String pdfHash(List<int> bytes) => sha256.convert(bytes).toString();

const tables = <String>[
  'folders', 'documents', 'categories', 'tags', 'document_tags', 'reminders',
  'history', 'settings', 'document_text_index', 'smart_collections',
];

Future<File> makeArchive(Directory folder, String series, String name, {
  required List<String> documents,
  required List<String> payloadDocuments,
  required String? parent,
}) async {
  await folder.create(recursive: true);
  final archive = Archive();
  final metadata = <Map<String, Object?>>[];
  for (final table in tables) {
    final rows = table == 'documents'
        ? documents.map((id) => <String, Object?>{
          'id': id,
          'name': id, 'mime_type': 'application/pdf',
          'sha256': pdfHash(pdfBytes(id)),
          'size_bytes': pdfBytes(id).length,
        }).toList()
        : <Map<String, Object?>>[];
    final bytes = utf8.encode(jsonEncode(rows));
    final entry = table + '.json';
    archive.addFile(ArchiveFile(entry, bytes.length, bytes));
    metadata.add({
      'entry': entry, 'sizeBytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    });
  }
  final payloads = <Map<String, Object?>>[];
  for (final id in payloadDocuments) {
    final bytes = pdfBytes(id);
    final entry = 'pdfs/' + id + '.pdf';
    archive.addFile(ArchiveFile(entry, bytes.length, bytes));
    payloads.add({
      'documentId': id, 'entry': entry,
      'sha256': pdfHash(bytes), 'originalName': id + '.pdf',
    });
  }
  final manifest = <String, Object?>{
    'format': 'DocsGridBackup', 'version': 1,
    'backupType': parent == null ? 'full' : 'incremental',
    'backupId': series + '-' + name,
    'seriesId': series, 'backupName': name, 'parentName': parent,
    'parentBackupId': parent == null ? null : series + '-' + parent,
    'metadataFiles': metadata, 'files': payloads,
    'documentFingerprints': [
      for (final id in documents) {
        'id': id, 'sha256': pdfHash(pdfBytes(id)),
        'sizeBytes': pdfBytes(id).length,
        'modifiedMillis': 0,
      },
    ],
    'tables': {for (final t in tables) t: t == 'documents' ? documents.length : 0},
    'deletedDocumentIds': <String>[],
  };
  final bytes = utf8.encode(jsonEncode(manifest));
  archive.addFile(ArchiveFile('manifest.json', bytes.length, bytes));
  final file = File(p.join(folder.path, name + '.zip'));
  await file.writeAsBytes(ZipEncoder().encode(archive), flush: true);
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late Directory full;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('docsgrid_series_test_');
    full = Directory(p.join(temporary.path, 'Full'));
    await full.create(recursive: true);
  });
  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('legacy reader verifies Full and incremental parent sequence', () async {
    final folder = Directory(p.join(full.path, 'A001'));
    await makeArchive(folder, 'A001', 'A001',
        parent: null, documents: ['one'], payloadDocuments: ['one']);
    await makeArchive(folder, 'A001', 'I001',
        parent: 'A001', documents: ['one', 'two'], payloadDocuments: ['two']);
    await makeArchive(folder, 'A001', 'I002',
        parent: 'I001', documents: ['one', 'two'], payloadDocuments: []);
    final members = await BackupChain.verified(folder);
    expect(members.map((file) => p.basename(file.path)), ['A001.zip', 'I001.zip', 'I002.zip']);
    final last = await BackupChain.manifest(members.last);
    expect(last['parentName'], 'I001');
    expect(BackupChain.fingerprints(last).length, 2);
  });

  test('legacy series discovery follows numeric order past A999', () async {
    await Directory(p.join(full.path, 'A1000')).create();
    await Directory(p.join(full.path, 'A999')).create();
    final folders = await BackupChain.folders(full);
    expect(folders.map((folder) => p.basename(folder.path)), ['A999', 'A1000']);
  });

  test('only new payloads are saved, but last restore recovers all bytes', () async {
    final dir = Directory(p.join(full.path, 'A001'));
    await makeArchive(dir, 'A001', 'A001',
        parent: null, documents: ['one'], payloadDocuments: ['one']);
    final incremental = await makeArchive(dir, 'A001', 'I001',
        parent: 'A001', documents: ['one', 'two'], payloadDocuments: ['two']);
    final incManifest = await BackupChain.manifest(incremental);
    expect((incManifest['files'] as List), hasLength(1));
    final composed = await BackupChain.compose(incremental, temporary);
    final restored = await BackupChain.manifest(composed);
    expect(restored['backupType'], 'full');
    expect(restored['files'], hasLength(2));
    expect(await composed.exists(), true);
  });

  test('parent UUID mismatch blocks an otherwise correctly named chain', () async {
    final folder = Directory(p.join(full.path, 'A001'));
    await makeArchive(folder, 'A001', 'A001',
        parent: null, documents: ['one'], payloadDocuments: ['one']);
    final increment = await makeArchive(folder, 'A001', 'I001',
        parent: 'A001', documents: ['one', 'two'], payloadDocuments: ['two']);
    final originalBytes = await increment.readAsBytes();
    // A named parent without a matching immutable backup UUID is not trusted.
    // Use a direct manifest mutation and re-encode, retaining valid ZIP bytes.
    final decoded = ZipDecoder().decodeBytes(originalBytes);
    final entry = decoded.findFile('manifest.json')!;
    final data = jsonDecode(utf8.decode(entry.content as List<int>))
        as Map<String, dynamic>;
    data['parentBackupId'] = 'different-parent-id';
    // ZipDecoder returns an immutable file list. Construct a new Archive
    // instead of mutating it so this test reaches the parent UUID assertion.
    final rebuilt = Archive();
    for (final file in decoded.files) {
      if (file.name != 'manifest.json') rebuilt.addFile(file);
    }
    final bytes = utf8.encode(jsonEncode(data));
    rebuilt.addFile(ArchiveFile('manifest.json', bytes.length, bytes));
    await increment.writeAsBytes(ZipEncoder().encode(rebuilt), flush: true);
    await expectLater(BackupChain.verified(folder), throwsStateError);
    expect(await File(p.join(folder.path, 'A001.zip')).exists(), true);
  });

  test('missing parent prevents both restore and automatic cleanup', () async {
    final dir = Directory(p.join(full.path, 'A001'));
    await makeArchive(dir, 'A001', 'A001',
        parent: null, documents: ['one'], payloadDocuments: ['one']);
    await makeArchive(dir, 'A001', 'I001',
        parent: 'A001', documents: ['one', 'two'], payloadDocuments: ['two']);
    final inc2 = await makeArchive(dir, 'A001', 'I002',
        parent: 'I001', documents: ['one', 'two'], payloadDocuments: []);
    await File(p.join(dir.path, 'I001.zip')).delete();
    await expectLater(BackupChain.compose(inc2, temporary), throwsStateError);
    await expectLater(BackupChain.deleteSeries(full, 'A001'), throwsStateError);
    expect(await File(p.join(dir.path, 'A001.zip')).exists(), true);
  });

  test('clean removes a complete series but leaves user library untouched', () async {
    final userPdf = File(p.join(temporary.path, 'Policy.pdf'));
    await userPdf.writeAsBytes(pdfBytes('policy'));
    final dir = Directory(p.join(full.path, 'A001'));
    await makeArchive(dir, 'A001', 'A001',
        parent: null, documents: ['one'], payloadDocuments: ['one']);
    await makeArchive(dir, 'A001', 'I001',
        parent: 'A001', documents: ['one'], payloadDocuments: []);
    final usage = await BackupChain.usage(full);
    expect(usage.single.files, 2);
    expect(usage.single.bytes, greaterThan(0));
    final freed = await BackupChain.deleteSeries(full, 'A001');
    expect(freed, usage.single.bytes);
    expect(await dir.exists(), false);
    expect(await userPdf.exists(), true);
  });

  test('unexpected file blocks series cleanup rather than deleting it', () async {
    final dir = Directory(p.join(full.path, 'A001'));
    await makeArchive(dir, 'A001', 'A001',
        parent: null, documents: ['one'], payloadDocuments: ['one']);
    await File(p.join(dir.path, 'unknown.txt')).writeAsString('do not delete');
    await expectLater(BackupChain.deleteSeries(full, 'A001'), throwsStateError);
    expect(await File(p.join(dir.path, 'unknown.txt')).exists(), true);
  });
}
