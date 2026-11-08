import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';
import '../../core/storage/storage_location_service.dart';
import '../reminders/data/reminder_notifications.dart';
import 'document_crop_screen.dart';

/// Local-only utilities for indexing, scanning, sharing and portable backups.
/// This service never uploads document contents to a remote server.
class DocumentToolsService {
  DocumentToolsService({AppDatabase? database})
      : _database = database ?? AppDatabase.instance;

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<List<Map<String, Object?>>> findExactDuplicates() async {
    final db = await _database.database;
    return db.rawQuery('''
      SELECT sha256, COUNT(*) AS copies, GROUP_CONCAT(id) AS document_ids,
             GROUP_CONCAT(name, ' | ') AS names
      FROM documents
      WHERE deleted_at IS NULL AND sha256 IS NOT NULL AND sha256 <> ''
      GROUP BY sha256 HAVING COUNT(*) > 1
      ORDER BY copies DESC
    ''');
  }

  Future<void> keepOneDuplicate(String sha, String keepId) async {
    final db = await _database.database;
    final matches = await db.query('documents',
      columns: ['id'], where: 'sha256 = ? AND deleted_at IS NULL',
      whereArgs: [sha]);
    if (matches.length < 2 || !matches.any((r) => r['id'] == keepId)) {
      throw StateError('Duplicate group changed. Refresh the list and try again.');
    }
    // Deliberately do not delete files. User must review each duplicate and
    // use the normal Recycle Bin flow so original files remain recoverable.
    throw StateError('Use Recycle Bin to remove reviewed copies individually. No file was deleted.');
  }

  Future<int> indexPdfText(String documentId, String path) async {
    final file = File(path);
    if (!await file.exists()) throw StateError('PDF is not available on this device.');
    final header = await file.openRead(0, 5).fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    if (header.length < 5 || String.fromCharCodes(header) != '%PDF-') {
      throw StateError('The selected file is not a valid PDF.');
    }
    final document = await pdfx.PdfDocument.openFile(path);
    final pageCount = document.pagesCount;
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    final pages = <String>[];
    try {
      for (var pageNumber = 1; pageNumber <= document.pagesCount; pageNumber++) {
        final page = await document.getPage(pageNumber);
        try {
          final rendered = await page.render(
            width: (page.width * 1.5).clamp(900, 1800).toDouble(),
            height: (page.height * 1.5).clamp(900, 2400).toDouble(),
            format: pdfx.PdfPageImageFormat.png,
          );
          if (rendered == null) continue;
          final temp = await getTemporaryDirectory();
          final image = File(p.join(temp.path, 'ocr_${_uuid.v4()}.png'));
          await image.writeAsBytes(rendered.bytes, flush: true);
          try {
            final result = await recognizer.processImage(InputImage.fromFilePath(image.path));
            pages.add('--- Page $pageNumber ---\n${result.text}');
          } finally {
            if (await image.exists()) await image.delete();
          }
        } finally {
          await page.close();
        }
      }
    } finally {
      await recognizer.close();
      await document.close();
    }
    final text = pages.join('\n\n').trim();
    final db = await _database.database;
    await db.insert('document_text_index', {
      'document_id': documentId,
      'extracted_text': text,
      'indexed_at': DateTime.now().toUtc().toIso8601String(),
      'page_count': pageCount,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.update('documents', {'extracted_text_status': text.isEmpty ? 'empty' : 'indexed'},
      where: 'id = ?', whereArgs: [documentId]);
    return text.length;
  }


  Future<int> indexPdfTextFromUri(String documentId, String storageUri) async {
    if (storageUri.startsWith('content://') || storageUri.startsWith('file://')) {
      final temp = await getTemporaryDirectory();
      final file = File(p.join(temp.path, 'ocr_source_${_uuid.v4()}.pdf'));
      try {
        await StorageLocationService.instance.copyPdfToPath(
          sourceUri: storageUri,
          destinationPath: file.path,
        );
        return await indexPdfText(documentId, file.path);
      } finally {
        if (await file.exists()) await file.delete();
      }
    }
    final path = storageUri.startsWith('file://')
        ? Uri.parse(storageUri).toFilePath()
        : storageUri;
    return indexPdfText(documentId, path);
  }

  Future<List<Map<String, Object?>>> searchText(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final db = await _database.database;
    return db.rawQuery('''
      SELECT d.id, d.name, d.storage_uri, i.extracted_text,
             instr(lower(i.extracted_text), lower(?)) AS match_position
      FROM document_text_index i
      JOIN documents d ON d.id = i.document_id
      WHERE d.deleted_at IS NULL AND i.extracted_text LIKE ?
      ORDER BY match_position ASC, d.name COLLATE NOCASE
    ''', [q, '%$q%']);
  }

  Future<File?> scanToPdf({
    required BuildContext context,
    bool useCamera = false,
  }) async {
    final picker = ImagePicker();
    final selected = useCamera
        ? _singleImage(await picker.pickImage(source: ImageSource.camera, imageQuality: 95))
        : await picker.pickMultiImage(imageQuality: 95);
    if (selected.isEmpty) return null;

    final pdf = pw.Document();
    for (final image in selected) {
      final originalBytes = await image.readAsBytes();
      if (!context.mounted) return null;
      final croppedBytes = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(
          builder: (_) => DocumentCropScreen(imageBytes: originalBytes),
          fullscreenDialog: true,
        ),
      );
      if (croppedBytes == null) return null;
      final memory = pw.MemoryImage(croppedBytes);
      pdf.addPage(pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(16),
        build: (_) => pw.Center(child: pw.Image(memory, fit: pw.BoxFit.contain)),
      ));
    }
    final directory = await getTemporaryDirectory();
    final scans = Directory(p.join(directory.path, 'DocsGrid', 'Scans'));
    await scans.create(recursive: true);
    final file = File(p.join(scans.path, 'Scan_${DateTime.now().microsecondsSinceEpoch}.pdf'));
    await file.writeAsBytes(await pdf.save(), flush: true);
    return file;
  }

  List<XFile> _singleImage(XFile? image) => image == null ? <XFile>[] : <XFile>[image];


  Future<void> shareStoredPdf(String storageUri, String displayName) async {
    String path;
    if (storageUri.startsWith('content://')) {
      final temp = await getTemporaryDirectory();
      final safeName = p.basename(displayName).replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
      final target = File(p.join(temp.path, 'share_${DateTime.now().microsecondsSinceEpoch}_$safeName'));
      await StorageLocationService.instance.copyPdfToPath(
        sourceUri: storageUri,
        destinationPath: target.path,
      );
      path = target.path;
    } else {
      path = storageUri.startsWith('file://') ? Uri.parse(storageUri).toFilePath() : storageUri;
    }
    final file = File(path);
    if (!await file.exists()) throw StateError('PDF is no longer available to share.');
    await SharePlus.instance.share(ShareParams(files: [XFile(path)], text: displayName));
  }

  Future<void> shareFile(String path, {String? text}) async {
    final file = File(path);
    if (!await file.exists()) throw StateError('File is no longer available.');
    await SharePlus.instance.share(ShareParams(files: [XFile(path)], text: text));
  }

  Future<File> createBackup({void Function(int, int)? onProgress}) async {
    final db = await _database.database;
    final archive = Archive();
    final tables = ['folders', 'documents', 'categories', 'tags',
      'document_tags', 'reminders', 'history', 'settings', 'document_text_index'];
    final manifest = <String, Object?>{
      'format': 'DocsGridBackup',
      'version': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'tables': <String, int>{},
      'files': <Map<String, Object?>>[],
    };
    for (final table in tables) {
      final rows = await db.query(table);
      (manifest['tables'] as Map<String, int>)[table] = rows.length;
      archive.addFile(ArchiveFile('$table.json', utf8.encode(jsonEncode(rows)).length,
        Uint8List.fromList(utf8.encode(jsonEncode(rows)))));
    }
    final docs = await db.query('documents',
      columns: ['id', 'name', 'storage_uri', 'sha256']);
    var completed = 0;
    for (final row in docs) {
      final uri = row['storage_uri'] as String?;
      if (uri == null || uri.isEmpty) {
        throw StateError('Backup cannot be complete: "${row['name']}" has no storage reference.');
      }
      File? stagedProviderFile;
      final File file;
      if (uri.startsWith('content://')) {
        final temp = await getTemporaryDirectory();
        stagedProviderFile = File(p.join(temp.path, 'backup_${_uuid.v4()}.pdf'));
        await StorageLocationService.instance.copyPdfToPath(
          sourceUri: uri,
          destinationPath: stagedProviderFile.path,
        );
        file = stagedProviderFile;
      } else {
        file = File(uri.startsWith('file://') ? Uri.parse(uri).toFilePath() : uri);
      }
      try {
        if (!await file.exists()) {
          throw StateError('Backup cannot be complete: "${row['name']}" is unavailable. Repair storage access and retry.');
        }
        final bytes = await file.readAsBytes();
        final digest = sha256.convert(bytes).toString();
        final expected = row['sha256'] as String?;
        if (expected != null && expected.isNotEmpty && digest != expected) {
          throw StateError('Backup stopped: "${row['name']}" failed SHA-256 verification.');
        }
        final entry = 'pdfs/${row['id']}.pdf';
        archive.addFile(ArchiveFile(entry, bytes.length, bytes));
        (manifest['files'] as List).add({
          'documentId': row['id'], 'entry': entry, 'sha256': digest,
          'originalName': row['name'],
        });
      } finally {
        if (stagedProviderFile != null && await stagedProviderFile.exists()) {
          await stagedProviderFile.delete();
        }
      }
      completed++;
      onProgress?.call(completed, docs.length);
    }
    final manifestBytes = utf8.encode(jsonEncode(manifest));
    archive.addFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));
    final zipped = ZipEncoder().encode(archive);
    final directory = await getApplicationDocumentsDirectory();
    final backups = Directory(p.join(directory.path, 'DocsGrid', 'Backups'));
    await backups.create(recursive: true);
    final output = File(p.join(backups.path, 'DocsGrid_${DateTime.now().toUtc().millisecondsSinceEpoch}.zip'));
    await output.writeAsBytes(zipped, flush: true);
    return output;
  }


  /// Additively restores a verified archive. Existing document/folder IDs are
  /// never overwritten; any collision aborts the database transaction.
  Future<int> restoreBackup(File zipFile) async {
    await validateBackup(zipFile);
    final decoded = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    final manifestFile = decoded.findFile('manifest.json')!;
    final manifest = jsonDecode(utf8.decode(manifestFile.content as List<int>)) as Map<String, dynamic>;
    final tableNames = ['folders', 'documents', 'categories', 'tags',
      'document_tags', 'reminders', 'history', 'settings', 'document_text_index'];
    final rowsByTable = <String, List<Map<String, Object?>>>{};
    for (final table in tableNames) {
      final entry = decoded.findFile('$table.json');
      // Older v1 backups predate OCR indexing; keep them restorable.
      if (entry == null && table == 'document_text_index') {
        rowsByTable[table] = <Map<String, Object?>>[];
        continue;
      }
      if (entry == null) throw StateError('Backup is incomplete: missing $table metadata.');
      final rows = jsonDecode(utf8.decode(entry.content as List<int>)) as List<dynamic>;
      rowsByTable[table] = rows.map((e) => Map<String, Object?>.from(e as Map)).toList();
    }

    final root = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'DocsGrid', 'Restored'));
    final restoreRoot = Directory(p.join(root.path, DateTime.now().microsecondsSinceEpoch.toString()));
    await restoreRoot.create(recursive: true);
    final fileRows = (manifest['files'] as List<dynamic>).cast<Map<String, dynamic>>();
    final restoredPaths = <String, String>{};
    final folderRows = rowsByTable['folders']!;
    final folderPaths = <String, String>{};
    String folderPath(String id) {
      final known = folderPaths[id];
      if (known != null) return known;
      final row = folderRows.firstWhere((r) => r['id'] == id);
      final parent = row['parent_id'] as String?;
      final base = parent == null ? restoreRoot.path : folderPath(parent);
      final path = p.join(base, 'folder_$id');
      folderPaths[id] = path;
      return path;
    }

    var databaseCommitted = false;
    try {
      for (final row in folderRows) {
        await Directory(folderPath(row['id'] as String)).create(recursive: true);
      }
      for (final item in fileRows) {
        final id = item['documentId'] as String;
        final document = rowsByTable['documents']!.firstWhere((r) => r['id'] == id);
        final folderId = document['folder_id'] as String?;
        final destinationDir = folderId == null ? restoreRoot : Directory(folderPath(folderId));
        await destinationDir.create(recursive: true);
        final safeName = p.basename((item['originalName'] as String?) ?? 'document.pdf');
        final destination = File(p.join(destinationDir.path, '${id}_$safeName'));
        final entry = decoded.findFile(item['entry'] as String)!;
        final bytes = entry.content as List<int>;
        final digest = sha256.convert(bytes).toString();
        if (digest != item['sha256']) throw StateError('PDF integrity check failed during restore.');
        await destination.writeAsBytes(bytes, flush: true);
        restoredPaths[id] = destination.path;
      }

      final db = await _database.database;
      await db.transaction((txn) async {
        for (final row in folderRows) {
          final copy = Map<String, Object?>.from(row);
          copy['storage_uri_or_relative_path'] = folderPath(row['id'] as String);
          await txn.insert('folders', copy);
        }
        for (final row in rowsByTable['categories']!) {
          await txn.insert('categories', row, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        for (final row in rowsByTable['tags']!) {
          await txn.insert('tags', row);
        }
        for (final row in rowsByTable['documents']!) {
          final copy = Map<String, Object?>.from(row);
          final restored = restoredPaths[row['id']];
          if (restored == null) throw StateError('Backup is missing PDF bytes for "${row['name']}".');
          copy['storage_uri'] = restored;
          await txn.insert('documents', copy);
        }
        for (final table in ['document_tags', 'reminders', 'history', 'document_text_index']) {
          for (final row in rowsByTable[table]!) {
            await txn.insert(table, row);
          }
        }
        // Preferences are additive: never overwrite settings already configured
        // on this device when importing a backup from another installation.
        for (final row in rowsByTable['settings']!) {
          await txn.insert('settings', row, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      });
      databaseCommitted = true;
      for (final row in rowsByTable['reminders']!) {
        if ((row['enabled'] as int? ?? 0) != 1 || row['status'] == 'completed') continue;
        final at = DateTime.parse(row['remind_at_utc'] as String).toLocal();
        try {
          await ReminderNotifications.instance.schedule(
            id: row['id'] as String,
            title: row['title'] as String,
            body: row['note'] as String?,
            at: at,
            recurrence: row['recurrence_rule'] as String?,
          );
        } catch (_) {
          // Imported records remain valid even if the OS declines a notification.
        }
      }
      return restoredPaths.length;
    } catch (_) {
      if (!databaseCommitted && await restoreRoot.exists()) {
        await restoreRoot.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<int> validateBackup(File zipFile) async {
    if (!await zipFile.exists()) throw StateError('Backup file not found.');
    final decoded = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    final manifestFile = decoded.findFile('manifest.json');
    if (manifestFile == null) throw StateError('This is not a DocsGrid backup.');
    final manifest = jsonDecode(utf8.decode(manifestFile.content as List<int>)) as Map<String, dynamic>;
    if (manifest['format'] != 'DocsGridBackup' || manifest['version'] != 1) {
      throw StateError('Unsupported backup format or version.');
    }
    final files = (manifest['files'] as List<dynamic>? ?? []);
    for (final raw in files) {
      final item = raw as Map<String, dynamic>;
      final entry = decoded.findFile(item['entry'] as String);
      if (entry == null) throw StateError('Backup is incomplete: missing PDF entry.');
      final digest = sha256.convert(entry.content as List<int>).toString();
      if (digest != item['sha256']) throw StateError('Backup integrity check failed.');
    }
    return files.length;
  }
}
