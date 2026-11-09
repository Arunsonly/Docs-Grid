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
import 'backup_archive_limits.dart';
import 'document_crop_screen.dart';
import 'portable_snapshot_manifest.dart';

/// Local-only utilities for indexing, scanning, sharing and portable backups.
/// This service never uploads document contents to a remote server.
class DocumentToolsService {
  DocumentToolsService({AppDatabase? database})
      : _database = database ?? AppDatabase.instance;

  final AppDatabase _database;
  static const _uuid = Uuid();

  /// Converts untrusted backup IDs into safe, deterministic path segments.
  /// Raw database IDs must never be interpolated into filesystem paths.
  @visibleForTesting
  static String safeRestorePathToken(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  /// Escapes user text for a literal SQLite LIKE substring search.
  @visibleForTesting
  static String escapeLikeQuery(String value) {
    final slash = String.fromCharCode(92);
    return value
        .replaceAll(slash, '$slash$slash')
        .replaceAll('%', '$slash%')
        .replaceAll('_', '${slash}_');
  }

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

  Future<int> keepOneDuplicate(String sha, String keepId) async {
    final db = await _database.database;
    final candidates = await db.query(
      'documents',
      columns: ['id', 'storage_uri', 'sha256'],
      where: 'sha256 = ? AND deleted_at IS NULL',
      whereArgs: [sha],
    );
    if (candidates.length < 2 || !candidates.any((row) => row['id'] == keepId)) {
      throw StateError('Duplicate group changed. Refresh the list and try again.');
    }

    // Re-hash every current file before moving anything. A PDF edited outside
    // DocsGrid must not be trashed merely because its old indexed hash matches.
    for (final candidate in candidates) {
      final uri = candidate['storage_uri'] as String?;
      if (uri == null || uri.isEmpty) {
        throw StateError('A duplicate copy has no storage location; no copies were moved.');
      }
      final actualDigest = uri.startsWith('content://') || uri.startsWith('file://')
          ? await StorageLocationService.instance.sha256Pdf(uri)
          : await _hashLocalFile(File(uri));
      if (actualDigest != sha) {
        throw StateError('A duplicate copy has changed since indexing. Refresh duplicate detection; no copies were moved.');
      }
    }

    return db.transaction((txn) async {
      final current = await txn.query(
        'documents',
        columns: ['id'],
        where: 'sha256 = ? AND deleted_at IS NULL',
        whereArgs: [sha],
      );
      final expectedIds = candidates.map((row) => row['id'] as String).toSet();
      final currentIds = current.map((row) => row['id'] as String).toSet();
      if (currentIds.length != expectedIds.length || !currentIds.containsAll(expectedIds)) {
        throw StateError('Duplicate group changed during review. No copies were moved.');
      }
      final now = DateTime.now().toUtc().toIso8601String();
      var moved = 0;
      for (final id in expectedIds) {
        if (id == keepId) continue;
        final changed = await txn.update(
          'documents',
          {'deleted_at': now, 'updated_at': now},
          where: 'id = ? AND sha256 = ? AND deleted_at IS NULL',
          whereArgs: [id, sha],
        );
        if (changed == 1) {
          await txn.insert('history', {
            'id': _uuid.v4(),
            'document_id': id,
            'action': 'moved_to_recycle_bin',
            'details_json': jsonEncode({'duplicateReview': true, 'keptDocumentId': keepId}),
            'created_at': now,
          });
          moved++;
        }
      }
      if (moved != expectedIds.length - 1) {
        throw StateError('Duplicate group changed during review. No copies were moved.');
      }
      return moved;
    });
  }

  Future<String> _hashLocalFile(File file) async {
    if (!await file.exists()) {
      throw StateError('A duplicate copy is missing; no copies were moved.');
    }
    return (await sha256.bind(file.openRead()).first).toString();
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
    final latinRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    // Android can bundle both scripts. iOS ML Kit currently supports Latin only.
    final devanagariRecognizer = Platform.isAndroid
        ? TextRecognizer(script: TextRecognitionScript.devanagiri)
        : null;
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
            final inputImage = InputImage.fromFilePath(image.path);
            final latinResult = await latinRecognizer.processImage(inputImage);
            final scriptResults = <String>[latinResult.text];
            if (devanagariRecognizer != null) {
              final devanagariResult = await devanagariRecognizer.processImage(inputImage);
              if (devanagariResult.text.trim().isNotEmpty &&
                  devanagariResult.text.trim() != latinResult.text.trim()) {
                scriptResults.add(devanagariResult.text);
              }
            }
            pages.add('--- Page $pageNumber ---\n${scriptResults.join('\n')}');
          } finally {
            if (await image.exists()) await image.delete();
          }
        } finally {
          await page.close();
        }
      }
    } finally {
      await latinRecognizer.close();
      await devanagariRecognizer?.close();
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
    final pattern = '%${escapeLikeQuery(q)}%';
    return db.rawQuery('''
      SELECT d.id, d.name, d.storage_uri, i.extracted_text,
             instr(lower(i.extracted_text), lower(?)) AS match_position
      FROM document_text_index i
      JOIN documents d ON d.id = i.document_id
      WHERE d.deleted_at IS NULL AND i.extracted_text LIKE ? ESCAPE '\\'
      ORDER BY match_position ASC, d.name COLLATE NOCASE
    ''', [q, pattern]);
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
    String? stagedPath;
    try {
      String path;
      if (storageUri.startsWith('content://')) {
        final temp = await getTemporaryDirectory();
        final safeName = p.basename(displayName).replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
        final target = File(p.join(temp.path, 'share_${DateTime.now().microsecondsSinceEpoch}_$safeName'));
        stagedPath = target.path;
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
    } finally {
      if (stagedPath != null) {
        try {
          final staged = File(stagedPath);
          if (await staged.exists()) await staged.delete();
        } catch (_) {
          // A temporary copy is non-authoritative; do not mask share errors.
        }
      }
    }
  }

  /// Shares several stored PDFs in one native share sheet.
  Future<void> shareManyStoredPdfs(List<String> storageUris, List<String> displayNames) async {
    if (storageUris.isEmpty || storageUris.length != displayNames.length) {
      throw ArgumentError('PDF locations and names must be non-empty and have matching lengths.');
    }
    final temp = await getTemporaryDirectory();
    final stagedPaths = <String>[];
    try {
      final files = <XFile>[];
      for (var i = 0; i < storageUris.length; i++) {
        final uri = storageUris[i];
        final safeName = p.basename(displayNames[i]).replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
        String path;
        if (uri.startsWith('content://')) {
          final target = File(p.join(temp.path, 'share_${DateTime.now().microsecondsSinceEpoch}_${i}_$safeName'));
          stagedPaths.add(target.path);
          await StorageLocationService.instance.copyPdfToPath(sourceUri: uri, destinationPath: target.path);
          path = target.path;
        } else {
          path = uri.startsWith('file://') ? Uri.parse(uri).toFilePath() : uri;
        }
        if (!await File(path).exists()) throw StateError('PDF is unavailable: ${displayNames[i]}');
        files.add(XFile(path, name: safeName));
      }
      await SharePlus.instance.share(ShareParams(files: files, text: 'DocsGrid documents'));
    } finally {
      for (final path in stagedPaths) {
        try {
          final staged = File(path);
          if (await staged.exists()) await staged.delete();
        } catch (_) {
          // Best-effort cleanup of temporary share copies.
        }
      }
    }
  }
  Future<void> shareFile(String path, {String? text}) async {
    final file = File(path);
    if (!await file.exists()) throw StateError('File is no longer available.');
    await SharePlus.instance.share(ShareParams(files: [XFile(path)], text: text));
  }

  Future<File> createBackup({void Function(int, int)? onProgress}) async {
    final db = await _database.database;
    final archive = Archive();
    var expandedBytes = 0;
    final tables = ['folders', 'documents', 'categories', 'tags',
      'document_tags', 'reminders', 'history', 'settings', 'document_text_index'];
    final manifest = <String, Object?>{
      'format': 'DocsGridBackup',
      'version': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'tables': <String, int>{},
      'metadataFiles': <Map<String, Object?>>[],
      'files': <Map<String, Object?>>[],
    };
    for (final table in tables) {
      final rows = await db.query(table);
      final metadataBytes = Uint8List.fromList(utf8.encode(jsonEncode(rows)));
      expandedBytes += metadataBytes.length;
      if (expandedBytes > BackupArchiveLimits.maxExpandedBytes) {
        throw StateError('Backup exceeds the supported uncompressed size limit.');
      }
      (manifest['tables'] as Map<String, int>)[table] = rows.length;
      archive.addFile(ArchiveFile('$table.json', metadataBytes.length, metadataBytes));
      (manifest['metadataFiles'] as List<Map<String, Object?>>).add({
        'entry': '$table.json',
        'sizeBytes': metadataBytes.length,
        'sha256': sha256.convert(metadataBytes).toString(),
        'recordCount': rows.length,
      });
    }
    final docs = await db.query('documents',
      columns: ['id', 'name', 'storage_uri', 'sha256']);
    if (docs.length + tables.length + 1 > BackupArchiveLimits.maxEntries) {
      throw StateError('Backup contains more entries than the supported limit.');
    }
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
        final sourceLength = await file.length();
        if (sourceLength > BackupArchiveLimits.maxEntryBytes ||
            expandedBytes + sourceLength > BackupArchiveLimits.maxExpandedBytes) {
          throw StateError('Backup exceeds the supported PDF or total size limit.');
        }
        final bytes = await file.readAsBytes();
        expandedBytes += bytes.length;
        if (bytes.length < 5 || String.fromCharCodes(bytes.take(5)) != '%PDF-') {
          throw StateError('Backup stopped: "${row['name']}" is not a valid PDF.');
        }
        final digest = sha256.convert(bytes).toString();
        final expected = row['sha256'] as String?;
        if (expected != null && expected.isNotEmpty && digest != expected) {
          throw StateError('Backup stopped: "${row['name']}" failed SHA-256 verification.');
        }
        final entry = 'pdfs/${safeRestorePathToken(row['id'] as String)}.pdf';
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
    if (expandedBytes + manifestBytes.length > BackupArchiveLimits.maxExpandedBytes) {
      throw StateError('Backup manifest exceeds the supported total size limit.');
    }
    archive.addFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));
    final zipped = ZipEncoder().encode(archive);
    if (zipped.length > BackupArchiveLimits.maxArchiveBytes) {
      throw StateError('Backup exceeds the supported compressed size limit.');
    }
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
    final visitingFolderIds = <String>{};
    String folderPath(String id) {
      final known = folderPaths[id];
      if (known != null) return known;
      if (!visitingFolderIds.add(id)) {
        throw StateError('Backup folder hierarchy contains a cycle.');
      }
      final row = folderRows.firstWhere((r) => r['id'] == id);
      final parent = row['parent_id'] as String?;
      final base = parent == null ? restoreRoot.path : folderPath(parent);
      final path = p.join(base, 'folder_${safeRestorePathToken(id)}');
      visitingFolderIds.remove(id);
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
        final safeDocumentToken = safeRestorePathToken(id);
        final destination = File(p.join(destinationDir.path, 'document_$safeDocumentToken.pdf'));
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
          // The restored staging tree is not the canonical private library
          // root, so no library-relative path can be asserted here.
          copy['relative_path'] = null;
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

  /// Writes a versioned, verified metadata snapshot into the user-selected
  /// DocsGrid/System/Database folder. PDF bytes remain in the library folder;
  /// documents.json retains their relative paths and SHA-256 values.
  Future<String> createPortableMetadataSnapshot() async {
    final locations = await StorageLocationService.instance.portableDataLocations();
    final db = await _database.database;
    final tableRows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    );
    final tableNames = tableRows
        .map((row) => row['name'] as String)
        .where((name) => name != 'android_metadata')
        .toList(growable: false);
    if (!tableNames.contains('documents') || !tableNames.contains('folders')) {
      throw StateError('The DocsGrid database is incomplete; no snapshot was written.');
    }

    final stamp = DateTime.now().toUtc().toIso8601String()
        .replaceAll(':', '-').replaceAll('.', '-');
    final snapshotName = 'snapshot_$stamp';
    final snapshotUri = await StorageLocationService.instance.createDirectory(
      parentUri: locations['databaseUri']!,
      name: snapshotName,
    );
    final fileRecords = <Map<String, Object?>>[];
    final recordCounts = <String, int>{};

    try {
      for (final table in tableNames) {
        final rows = await db.query(table);
        final contents = jsonEncode(rows);
        final bytes = utf8.encode(contents);
        final filename = '$table.json';
        await StorageLocationService.instance.writeTextFile(
          parentUri: snapshotUri,
          name: filename,
          contents: contents,
        );
        fileRecords.add({
          'path': filename,
          'sizeBytes': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
          'recordCount': rows.length,
        });
        recordCounts[table] = rows.length;
      }

      final manifest = <String, Object?>{
        'format': 'DocsGridPortableData',
        'formatVersion': 1,
        'databaseSchemaVersion': (await db.rawQuery('PRAGMA user_version')).first.values.first,
        'snapshotId': _uuid.v4(),
        'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
        'app': 'DocsGrid',
        'tables': recordCounts,
        'files': fileRecords,
        'libraryUri': locations['libraryUri'],
        'notes': 'PDF files remain in the selected library. This snapshot stores metadata and indexes.',
      };
      // Manifest is published last; folders without it are incomplete and
      // must never be treated as a valid recovery snapshot.
      await StorageLocationService.instance.writeTextFile(
        parentUri: snapshotUri,
        name: 'manifest.json',
        contents: jsonEncode(manifest),
      );
      return snapshotName;
    } catch (_) {
      // Keep the incomplete directory for diagnostics; without manifest it
      // cannot be selected as a valid recovery snapshot.
      rethrow;
    }
  }

  Future<Map<String, Object?>?> _findLatestVerifiedPortableSnapshot() async {
    final locations = await StorageLocationService.instance.portableDataLocations();
    final children = await StorageLocationService.instance.listDirectory(locations['databaseUri']!);
    final snapshots = children
        .where((entry) => entry['isDirectory'] == true &&
            (entry['name'] as String).startsWith('snapshot_'))
        .toList()
      ..sort((a, b) => (b['name'] as String).compareTo(a['name'] as String));

    // An interrupted snapshot has no manifest because it is published last.
    // Skip incomplete/corrupt candidates and fall back to the newest verified
    // snapshot rather than allowing one partial directory to block recovery.
    for (final snapshot in snapshots) {
      try {
        final snapshotUri = snapshot['uri'] as String;
        final manifestText = await StorageLocationService.instance.readTextFile(
          await _findChildUri(snapshotUri, 'manifest.json'),
        );
        final manifest = PortableSnapshotManifest.parse(manifestText);
        for (final record in manifest.files) {
          final uri = await _findChildUri(snapshotUri, record.path);
          final contents = await StorageLocationService.instance.readTextFile(uri);
          final bytes = utf8.encode(contents);
          if (bytes.length != record.sizeBytes ||
              sha256.convert(bytes).toString() != record.sha256) {
            throw StateError('Recovery snapshot verification failed for ${record.path}.');
          }
          final rows = jsonDecode(contents);
          if (rows is! List || rows.length != record.recordCount) {
            throw StateError('Recovery snapshot record count mismatch for ${record.path}.');
          }
        }
        return {
          'name': snapshot['name'] as String,
          'uri': snapshotUri,
          'manifest': manifest,
          'locations': locations,
        };
      } catch (_) {
        // Try the next older snapshot; never overwrite or delete any candidate.
      }
    }
    return null;
  }

  Future<String?> verifyLatestPortableMetadataSnapshot() async {
    final verified = await _findLatestVerifiedPortableSnapshot();
    return verified?['name'] as String?;
  }

  /// Restores the newest verified portable snapshot additively. Existing
  /// records are retained; imported IDs are remapped where needed. PDFs are
  /// relinked by SHA-256 from the currently selected library and never overwritten.
  Future<Map<String, int>> restoreLatestPortableMetadataSnapshot() async {
    final verified = await _findLatestVerifiedPortableSnapshot();
    if (verified == null) {
      throw StateError('No complete, verified DocsGrid recovery snapshot was found.');
    }
    final storage = StorageLocationService.instance;
    final locations = Map<String, String>.from(verified['locations'] as Map);
    final snapshotUri = verified['uri'] as String;
    final manifest = verified['manifest'] as PortableSnapshotManifest;
    if (manifest.databaseSchemaVersion > 3) {
      throw StateError('This recovery snapshot was created by a newer DocsGrid database version. Update the app before restoring it.');
    }
    final rowsByTable = <String, List<Map<String, Object?>>>{};
    for (final file in manifest.files) {
      final contents = await storage.readTextFile(
        await _findChildUri(snapshotUri, file.path),
      );
      final bytes = utf8.encode(contents);
      if (bytes.length != file.sizeBytes ||
          sha256.convert(bytes).toString() != file.sha256) {
        throw StateError('Snapshot integrity check failed for ${file.path}.');
      }
      final decoded = jsonDecode(contents);
      if (decoded is! List || decoded.length != file.recordCount) {
        throw StateError('Snapshot record count mismatch for ${file.path}.');
      }
      final table = file.path.substring(0, file.path.length - 5);
      if (!const {
        'folders', 'documents', 'categories', 'tags', 'document_tags',
        'reminders', 'history', 'settings', 'document_text_index', 'schema_migrations',
      }.contains(table)) {
        throw StateError('Snapshot contains unsupported table: $table.');
      }
      rowsByTable[table] = decoded
          .map((value) => Map<String, Object?>.from(value as Map))
          .toList();
    }
    for (final required in ['folders', 'documents', 'categories', 'tags',
      'document_tags', 'reminders', 'history', 'settings', 'document_text_index']) {
      rowsByTable.putIfAbsent(required, () => <Map<String, Object?>>[]);
    }

    final pdfUris = <String, String>{};
    final pending = <String>[locations['libraryUri']!];
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final directoryUri = pending.removeLast();
      if (!visited.add(directoryUri)) continue;
      final entries = await storage.listDirectory(directoryUri);
      for (final entry in entries) {
        final uri = entry['uri'] as String;
        final name = entry['name'] as String;
        if (entry['isDirectory'] == true) {
          pending.add(uri);
        } else if (name.toLowerCase().endsWith('.pdf')) {
          try {
            final digest = await storage.sha256Pdf(uri);
            pdfUris.putIfAbsent(digest, () => uri);
          } catch (_) {
            // Non-PDF provider entries and unreadable files are not candidates.
          }
        }
      }
    }

    final db = await _database.database;
    final existingFolders = await db.query('folders');
    final existingCategories = await db.query('categories');
    final existingTags = await db.query('tags');
    final existingDocuments = await db.query('documents');
    final existingReminders = await db.query('reminders');
    final existingHistory = await db.query('history');
    final folderRows = rowsByTable['folders']!;
    // Validate the entire graph before creating even one provider directory.
    // This rejects path traversal, duplicate IDs, missing parents and cycles.
    final folderRowsById = PortableSnapshotManifest.validateFolderRows(folderRows);
    final folderIdMap = <String, String>{};
    final folderUriMap = <String, String>{};
    final matchedFolderIds = <String>{};

    Future<String> ensureFolder(String oldId) async {
      final known = folderUriMap[oldId];
      if (known != null) return known;

      // Resolve ancestors iteratively so deeply nested valid libraries do not
      // overflow the Dart call stack during recovery.
      final chain = <String>[];
      String? currentId = oldId;
      while (currentId != null && !folderUriMap.containsKey(currentId)) {
        final row = folderRowsById[currentId];
        if (row == null) throw StateError('Snapshot refers to a missing parent folder.');
        chain.add(currentId);
        currentId = row['parent_id'] as String?;
      }

      for (final id in chain.reversed) {
        final row = folderRowsById[id]!;
        final parentId = row['parent_id'] as String?;
        final parentUri = parentId == null
            ? locations['libraryUri']!
            : folderUriMap[parentId]!;
        final rawName = row['name'] as String;
        final siblings = await storage.listDirectory(parentUri);
        final existing = siblings.where((entry) =>
            entry['isDirectory'] == true && entry['name'] == rawName);
        final uri = existing.isNotEmpty
            ? existing.first['uri'] as String
            : await storage.createDirectory(parentUri: parentUri, name: rawName);
        folderUriMap[id] = uri;
        final mappedParentId = parentId == null ? null : folderIdMap[parentId];
        final matchingFolder = existingFolders.where((candidate) =>
            candidate['name'] == rawName &&
            candidate['parent_id'] == mappedParentId &&
            candidate['deleted_at'] == null &&
            !matchedFolderIds.contains(candidate['id']));
        if (matchingFolder.isNotEmpty) {
          final existingFolder = matchingFolder.first;
          folderIdMap[id] = existingFolder['id'] as String;
          matchedFolderIds.add(existingFolder['id'] as String);
        } else {
          folderIdMap[id] = _uuid.v4();
        }
      }
      return folderUriMap[oldId]!;
    }

    for (final row in folderRows) {
      await ensureFolder(row['id'] as String);
    }

    final categoryIdMap = <String, String>{};
    final tagIdMap = <String, String>{};
    final documentIdMap = <String, String>{};
    final reminderIdMap = <String, String>{};
    final historyIdMap = <String, String>{};
    for (final row in rowsByTable['categories']!) {
      final oldId = row['id'] as String;
      final sameName = existingCategories.where((v) =>
          (v['name'] as String).toLowerCase() == (row['name'] as String).toLowerCase());
      final idTaken = existingCategories.any((v) => v['id'] == oldId);
      categoryIdMap[oldId] = sameName.isNotEmpty
          ? sameName.first['id'] as String
          : (idTaken ? _uuid.v4() : oldId);
    }
    for (final row in rowsByTable['tags']!) {
      final oldId = row['id'] as String;
      final sameName = existingTags.where((v) =>
          (v['name'] as String).toLowerCase() == (row['name'] as String).toLowerCase());
      final idTaken = existingTags.any((v) => v['id'] == oldId);
      tagIdMap[oldId] = sameName.isNotEmpty
          ? sameName.first['id'] as String
          : (idTaken ? _uuid.v4() : oldId);
    }
    for (final row in rowsByTable['documents']!) {
      final oldId = row['id'] as String;
      final digest = row['sha256'] as String?;
      final sameFile = digest == null ? const <Map<String, Object?>>[] :
          existingDocuments.where((v) => v['sha256'] == digest && v['deleted_at'] == null).toList();
      final idCollision = existingDocuments.any((v) => v['id'] == oldId);
      documentIdMap[oldId] = sameFile.isNotEmpty
          ? sameFile.first['id'] as String
          : (idCollision ? _uuid.v4() : oldId);
    }
    for (final row in rowsByTable['reminders']!) {
      final oldId = row['id'] as String;
      final mappedDocumentId = row['document_id'] == null
          ? null : documentIdMap[row['document_id']];
      final duplicate = existingReminders.where((v) =>
          v['document_id'] == mappedDocumentId &&
          v['title'] == row['title'] &&
          v['remind_at_utc'] == row['remind_at_utc'] &&
          v['enabled'] == row['enabled'] && v['status'] == row['status']);
      reminderIdMap[oldId] = duplicate.isNotEmpty
          ? duplicate.first['id'] as String
          : (existingReminders.any((v) => v['id'] == oldId) ? _uuid.v4() : oldId);
    }
    for (final row in rowsByTable['history']!) {
      final oldId = row['id'] as String;
      final mappedDocumentId = row['document_id'] == null
          ? null : documentIdMap[row['document_id']];
      final duplicate = existingHistory.where((v) =>
          v['document_id'] == mappedDocumentId &&
          v['action'] == row['action'] &&
          v['created_at'] == row['created_at'] &&
          v['details_json'] == row['details_json']);
      historyIdMap[oldId] = duplicate.isNotEmpty
          ? duplicate.first['id'] as String
          : (existingHistory.any((v) => v['id'] == oldId) ? _uuid.v4() : oldId);
    }

    var addedDocuments = 0;
    var linkedDocuments = 0;
    var missingPdfs = 0;
    await db.transaction((txn) async {
      for (final row in rowsByTable['categories']!) {
        final copy = Map<String, Object?>.from(row)
          ..['id'] = categoryIdMap[row['id']];
        await txn.insert('categories', copy, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final row in rowsByTable['tags']!) {
        final copy = Map<String, Object?>.from(row)
          ..['id'] = tagIdMap[row['id']];
        await txn.insert('tags', copy, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      final insertedFolders = <String>{};
      Future<void> insertFolder(String oldId) async {
        final chain = <String>[];
        String? currentId = oldId;
        while (currentId != null && !insertedFolders.contains(currentId)) {
          final row = folderRowsById[currentId];
          if (row == null) throw StateError('Snapshot folder parent is missing.');
          chain.add(currentId);
          currentId = row['parent_id'] as String?;
        }
        for (final id in chain.reversed) {
          if (!insertedFolders.add(id)) continue;
          final row = folderRowsById[id]!;
          final parentId = row['parent_id'] as String?;
          final mappedId = folderIdMap[id]!;
          final values = {
            ...row,
            'id': mappedId,
            'parent_id': parentId == null ? null : folderIdMap[parentId],
            'storage_uri_or_relative_path': folderUriMap[id],
          };
          if (existingFolders.any((candidate) => candidate['id'] == mappedId)) {
            await txn.update('folders', {
              'storage_uri_or_relative_path': folderUriMap[id],
            }, where: 'id = ?', whereArgs: [mappedId]);
          } else {
            await txn.insert('folders', values, conflictAlgorithm: ConflictAlgorithm.ignore);
          }
        }
      }
      for (final row in folderRows) {
        await insertFolder(row['id'] as String);
      }
      for (final row in rowsByTable['documents']!) {
        final oldId = row['id'] as String;
        final newId = documentIdMap[oldId]!;
        final alreadyPresent = existingDocuments.any((v) => v['id'] == newId);
        final digest = row['sha256'] as String?;
        final linkedUri = digest == null ? null : pdfUris[digest];
        if (alreadyPresent) {
          if (linkedUri != null) {
            await txn.update('documents', {'storage_uri': linkedUri},
              where: 'id = ?', whereArgs: [newId]);
            linkedDocuments++;
          }
          continue;
        }
        final copy = Map<String, Object?>.from(row)
          ..['id'] = newId
          ..['folder_id'] = row['folder_id'] == null ? null : folderIdMap[row['folder_id']]
          ..['category_id'] = row['category_id'] == null ? null : categoryIdMap[row['category_id']]
          ..['storage_uri'] = linkedUri
          ..['relative_path'] = null;
        if (linkedUri == null) {
          missingPdfs++;
          final metadata = <String, dynamic>{};
          final oldMetadata = copy['metadata_json'];
          if (oldMetadata is String && oldMetadata.isNotEmpty) {
            try { metadata.addAll(jsonDecode(oldMetadata) as Map<String, dynamic>); } catch (_) {}
          }
          metadata['docsGridRecoveryStatus'] = 'pdf_missing_relink_required';
          copy['metadata_json'] = jsonEncode(metadata);
        } else {
          linkedDocuments++;
        }
        await txn.insert('documents', copy);
        addedDocuments++;
      }
      for (final row in rowsByTable['document_tags']!) {
        final documentId = documentIdMap[row['document_id']];
        final tagId = tagIdMap[row['tag_id']];
        if (documentId == null || tagId == null) continue;
        await txn.insert('document_tags', {
          ...row, 'document_id': documentId, 'tag_id': tagId,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final row in rowsByTable['reminders']!) {
        final mappedId = reminderIdMap[row['id']]!;
        if (existingReminders.any((v) => v['id'] == mappedId)) continue;
        final copy = Map<String, Object?>.from(row)
          ..['id'] = mappedId
          ..['document_id'] = row['document_id'] == null ? null : documentIdMap[row['document_id']];
        await txn.insert('reminders', copy, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final row in rowsByTable['history']!) {
        final mappedId = historyIdMap[row['id']]!;
        if (existingHistory.any((v) => v['id'] == mappedId)) continue;
        final copy = Map<String, Object?>.from(row)
          ..['id'] = mappedId
          ..['document_id'] = row['document_id'] == null ? null : documentIdMap[row['document_id']];
        await txn.insert('history', copy, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final row in rowsByTable['document_text_index']!) {
        final documentId = documentIdMap[row['document_id']];
        if (documentId == null) continue;
        await txn.insert('document_text_index', {
          ...row, 'document_id': documentId,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      for (final row in rowsByTable['settings']!) {
        await txn.insert('settings', row, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });

    for (final row in rowsByTable['reminders']!) {
      if ((row['enabled'] as int? ?? 0) != 1 || row['status'] == 'completed') continue;
      try {
        await ReminderNotifications.instance.schedule(
          id: reminderIdMap[row['id']]!,
          title: row['title'] as String,
          body: row['note'] as String?,
          at: DateTime.parse(row['remind_at_utc'] as String).toLocal(),
          recurrence: row['recurrence_rule'] as String?,
        );
      } catch (_) {
        // The reminder record is restored even if the OS blocks notifications.
      }
    }
    return {
      'documentsAdded': addedDocuments,
      'documentsLinked': linkedDocuments,
      'pdfsMissing': missingPdfs,
    };
  }

  Future<String> _findChildUri(String parentUri, String name) async {
    final children = await StorageLocationService.instance.listDirectory(parentUri);
    Map<String, Object?>? match;
    for (final entry in children) {
      if (entry['name'] == name) {
        match = entry;
        break;
      }
    }
    if (match == null || match['isDirectory'] == true) {
      throw StateError('Recovery snapshot is missing $name.');
    }
    return match['uri'] as String;
  }

  Future<int> validateBackup(File zipFile) async {
    if (!await zipFile.exists()) throw StateError('Backup file not found.');
    await BackupArchiveLimits.validate(zipFile);
    final decoded = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    final manifestFile = decoded.findFile('manifest.json');
    if (manifestFile == null) throw StateError('This is not a DocsGrid backup.');
    final manifest = jsonDecode(utf8.decode(manifestFile.content as List<int>)) as Map<String, dynamic>;
    if (manifest['format'] != 'DocsGridBackup' || manifest['version'] != 1) {
      throw StateError('Unsupported backup format or version.');
    }

    // Newer v1 archives carry hashes for every metadata table. Older archives
    // remain readable, but all new archives are checked before restore.
    const expectedMetadataEntries = {
      'folders.json', 'documents.json', 'categories.json', 'tags.json',
      'document_tags.json', 'reminders.json', 'history.json', 'settings.json',
      'document_text_index.json',
    };
    final metadataFiles = manifest['metadataFiles'];
    if (metadataFiles != null) {
      if (metadataFiles is! List) throw StateError('Backup metadata manifest is invalid.');
      final seenMetadata = <String>{};
      for (final raw in metadataFiles) {
        if (raw is! Map || raw['entry'] is! String ||
            raw['sizeBytes'] is! int || raw['sha256'] is! String ||
            raw['recordCount'] is! int) {
          throw StateError('Backup contains an invalid metadata manifest record.');
        }
        final entryName = raw['entry'] as String;
        if (!expectedMetadataEntries.contains(entryName) || !seenMetadata.add(entryName)) {
          throw StateError('Backup contains an unsafe or duplicate metadata entry.');
        }
        final entry = decoded.findFile(entryName);
        if (entry == null) throw StateError('Backup is incomplete: missing $entryName.');
        final bytes = entry.content as List<int>;
        if (bytes.length != raw['sizeBytes'] ||
            sha256.convert(bytes).toString() != raw['sha256']) {
          throw StateError('Backup metadata integrity check failed for $entryName.');
        }
        final rows = jsonDecode(utf8.decode(bytes));
        if (rows is! List || rows.length != raw['recordCount']) {
          throw StateError('Backup metadata record count mismatch for $entryName.');
        }
      }
      if (!seenMetadata.containsAll(expectedMetadataEntries)) {
        throw StateError('Backup is incomplete: one or more metadata tables are missing.');
      }
    }

    final documentsFile = decoded.findFile('documents.json');
    if (documentsFile == null) throw StateError('Backup is incomplete: missing document metadata.');
    final rawDocuments = jsonDecode(utf8.decode(documentsFile.content as List<int>));
    if (rawDocuments is! List) throw StateError('Backup document metadata is invalid.');
    final documentIds = <String>{};
    final documentsById = <String, Map>{};
    final backslash = String.fromCharCode(92);
    for (final raw in rawDocuments) {
      if (raw is! Map || raw['id'] is! String || (raw['id'] as String).trim().isEmpty ||
          !documentIds.add(raw['id'] as String)) {
        throw StateError('Backup contains invalid or duplicate document IDs.');
      }
      final documentName = raw['name'];
      if (documentName is! String || documentName.trim().isEmpty ||
          documentName == '.' || documentName == '..' ||
          documentName.contains('/') || documentName.contains(backslash) ||
          documentName.contains(String.fromCharCode(0)) ||
          documentName.runes.any((rune) => rune < 32 || rune == 127)) {
        throw StateError('Backup contains an unsafe document name.');
      }
      documentsById[raw['id'] as String] = raw;
    }

    // Folder names are later used as path segments by private-storage
    // operations. Validate the untrusted archive before any database or file
    // writes so a crafted backup cannot inject ../ or platform separators.
    final foldersFile = decoded.findFile('folders.json');
    if (foldersFile == null) throw StateError('Backup is incomplete: missing folder metadata.');
    final rawFolders = jsonDecode(utf8.decode(foldersFile.content as List<int>));
    if (rawFolders is! List) throw StateError('Backup folder metadata is invalid.');
    final folderIds = <String>{};
    final parentById = <String, String?>{};
    final siblingNames = <String>{};
    for (final raw in rawFolders) {
      if (raw is! Map || raw['id'] is! String || (raw['id'] as String).trim().isEmpty ||
          !folderIds.add(raw['id'] as String) || raw['name'] is! String) {
        throw StateError('Backup contains invalid or duplicate folder records.');
      }
      final name = raw['name'] as String;
      if (name.trim().isEmpty || name == '.' || name == '..' ||
          name.contains('/') || name.contains(backslash) ||
          name.contains(String.fromCharCode(0)) ||
          name.runes.any((rune) => rune < 32 || rune == 127)) {
        throw StateError('Backup contains an unsafe folder name.');
      }
      final parentId = raw['parent_id'];
      if (parentId != null && parentId is! String) {
        throw StateError('Backup contains an invalid folder parent reference.');
      }
      parentById[raw['id'] as String] = parentId as String?;
      final siblingKey = '${parentId ?? ''}::${name.toLowerCase()}';
      if (!siblingNames.add(siblingKey)) {
        throw StateError('Backup contains duplicate sibling folder names.');
      }
    }
    for (final entry in parentById.entries) {
      if (entry.value != null && !folderIds.contains(entry.value)) {
        throw StateError('Backup contains a folder with a missing parent.');
      }
    }
    final folderVisitState = <String, int>{};
    for (final id in folderIds) {
      final chain = <String>[];
      String? current = id;
      while (current != null && folderVisitState[current] != 2) {
        if (folderVisitState[current] == 1) {
          throw StateError('Backup folder hierarchy contains a cycle.');
        }
        folderVisitState[current] = 1;
        chain.add(current);
        current = parentById[current];
      }
      for (final visitedId in chain) {
        folderVisitState[visitedId] = 2;
      }
    }
    final categoriesFile = decoded.findFile('categories.json');
    if (categoriesFile == null) throw StateError('Backup is incomplete: missing category metadata.');
    final rawCategories = jsonDecode(utf8.decode(categoriesFile.content as List<int>));
    if (rawCategories is! List) throw StateError('Backup category metadata is invalid.');
    final categoryIds = <String>{};
    for (final raw in rawCategories) {
      if (raw is! Map || raw['id'] is! String || (raw['id'] as String).trim().isEmpty ||
          !categoryIds.add(raw['id'] as String)) {
        throw StateError('Backup contains invalid or duplicate category records.');
      }
    }
    for (final document in documentsById.values) {
      final folderId = document['folder_id'];
      final categoryId = document['category_id'];
      if (folderId != null && !folderIds.contains(folderId)) {
        throw StateError('Backup document refers to a missing folder.');
      }
      if (categoryId != null && !categoryIds.contains(categoryId)) {
        throw StateError('Backup document refers to a missing category.');
      }
    }

    final files = manifest['files'];
    if (files is! List) throw StateError('Backup PDF manifest is invalid.');
    final seenDocumentIds = <String>{};
    final seenEntries = <String>{};
    for (final raw in files) {
      if (raw is! Map || raw['documentId'] is! String ||
          raw['entry'] is! String || raw['sha256'] is! String) {
        throw StateError('Backup contains an invalid PDF manifest record.');
      }
      final documentId = raw['documentId'] as String;
      final entryName = raw['entry'] as String;
      final safeEntryName = 'pdfs/${safeRestorePathToken(documentId)}.pdf';
      final legacyEntryName = 'pdfs/$documentId.pdf';
      if (!documentIds.contains(documentId) ||
          (entryName != safeEntryName && entryName != legacyEntryName) ||
          !seenDocumentIds.add(documentId) ||
          !seenEntries.add(entryName) ||
          !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(raw['sha256'] as String)) {
        throw StateError('Backup contains an unsafe or inconsistent PDF entry.');
      }
      final entry = decoded.findFile(entryName);
      if (entry == null) throw StateError('Backup is incomplete: missing PDF entry.');
      final bytes = entry.content as List<int>;
      if (bytes.length < 5 || String.fromCharCodes(bytes.take(5)) != '%PDF-') {
        throw StateError('Backup contains a file that is not a valid PDF.');
      }
      final digest = sha256.convert(bytes).toString();
      if (digest != raw['sha256']) throw StateError('Backup integrity check failed.');
      final documentRecord = documentsById[documentId]!;
      final metadataDigest = documentRecord['sha256'];
      final metadataSize = documentRecord['size_bytes'];
      if ((metadataDigest != null && metadataDigest != digest) ||
          (metadataSize != null && metadataSize != bytes.length)) {
        throw StateError('Backup PDF metadata does not match the verified PDF bytes.');
      }
    }
    if (seenDocumentIds.length != documentIds.length) {
      throw StateError('Backup is incomplete: one or more document PDFs are missing.');
    }
    return files.length;
  }
}
