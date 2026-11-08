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
import 'portable_snapshot_manifest.dart';

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
    final rows = await db.rawQuery('''
      SELECT d.id, d.name, d.storage_uri, i.extracted_text,
             instr(lower(i.extracted_text), lower(?)) AS match_position
      FROM document_text_index i
      JOIN documents d ON d.id = i.document_id
      WHERE d.deleted_at IS NULL AND lower(i.extracted_text) LIKE lower(?)
      ORDER BY match_position ASC, d.name COLLATE NOCASE
    ''', [q, '%$q%']);
    // OCR stores an explicit page marker before every page. Resolve the page
    // containing the first match so search results are actionable, not just a
    // generic "text found" indication.
    for (final row in rows) {
      final text = row['extracted_text']?.toString() ?? '';
      final position = (row['match_position'] as int? ?? 1) - 1;
      final prefix = text.substring(0, position.clamp(0, text.length));
      final markers = RegExp(r'--- Page (\d+) ---').allMatches(prefix).toList();
      row['match_page'] = markers.isEmpty ? 1 : int.parse(markers.last.group(1)!);
    }
    return rows;
  }

  Future<File?> scanToPdf({
    required BuildContext context,
    bool useCamera = false,
  }) async {
    final picker = ImagePicker();
    var selected = useCamera
        ? _singleImage(await picker.pickImage(source: ImageSource.camera, imageQuality: 95))
        : await picker.pickMultiImage(imageQuality: 95);
    if (!context.mounted || selected.isEmpty) return null;
    if (selected.length > 1) {
      final ordered = List<XFile>.from(selected);
      final confirmedOrder = await showDialog<List<XFile>>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, refresh) => AlertDialog(
            title: const Text('Arrange page order'),
            content: SizedBox(
              width: 360,
              height: 320,
              child: ReorderableListView.builder(
                itemCount: ordered.length,
                onReorderItem: (oldIndex, newIndex) {
                  refresh(() {
                    final item = ordered.removeAt(oldIndex);
                    ordered.insert(newIndex, item);
                  });
                },
                itemBuilder: (context, index) => ListTile(
                  key: ValueKey(ordered[index].path),
                  leading: CircleAvatar(child: Text('${index + 1}')),
                  title: Text(ordered[index].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: ReorderableDragStartListener(index: index, child: const Icon(Icons.drag_handle)),
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(dialogContext, List<XFile>.from(ordered)), child: const Text('Continue')),
            ],
          ),
        ),
      );
      if (!context.mounted || confirmedOrder == null) return null;
      selected = confirmedOrder;
    }

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

  /// Shares several stored PDFs in one native share sheet.
  Future<void> shareManyStoredPdfs(List<String> storageUris, List<String> displayNames) async {
    if (storageUris.isEmpty || storageUris.length != displayNames.length) {
      throw ArgumentError('PDF locations and names must be non-empty and have matching lengths.');
    }
    final temp = await getTemporaryDirectory();
    final files = <XFile>[];
    final stagedFiles = <File>[];
    try {
      for (var i = 0; i < storageUris.length; i++) {
        final uri = storageUris[i];
        final safeName = p.basename(displayNames[i]).replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
        String path;
        if (uri.startsWith('content://')) {
          final target = File(p.join(temp.path, 'share_${_uuid.v4()}_$safeName'));
          stagedFiles.add(target);
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
      for (final file in stagedFiles) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {
          // Temporary share copies are best-effort cleanup; originals are untouched.
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
    final fileRows = (manifest['files'] as List<dynamic>).cast<Map<String, dynamic>>();
    final restoredPaths = <String, String>{};
    final folderRows = rowsByTable['folders']!;
    final folderRowsById = <String, Map<String, Object?>>{};
    for (final row in folderRows) {
      final id = row['id'];
      if (id is! String || id.isEmpty || folderRowsById.containsKey(id)) {
        throw StateError('Backup contains an invalid or duplicate folder ID.');
      }
      folderRowsById[id] = row;
    }
    final folderPaths = <String, String>{};
    final resolvingFolders = <String>{};
    String folderPath(String id) {
      final known = folderPaths[id];
      if (known != null) return known;
      if (!resolvingFolders.add(id)) {
        throw StateError('Backup folder hierarchy contains a cycle.');
      }
      try {
        final row = folderRowsById[id];
        if (row == null) throw StateError('Backup references a missing folder.');
        final parent = row['parent_id'] as String?;
        if (parent != null && !folderRowsById.containsKey(parent)) {
          throw StateError('Backup references a missing parent folder.');
        }
        final base = parent == null ? restoreRoot.path : folderPath(parent);
        // Never use untrusted archive IDs as filesystem path components.
        final path = p.join(base, 'folder_${_uuid.v4()}');
        folderPaths[id] = path;
        return path;
      } finally {
        resolvingFolders.remove(id);
      }
    }

    var databaseCommitted = false;
    try {
      // Create staging storage only after all folder IDs have been checked.
      // Invalid archives must fail before leaving any filesystem side effects.
      await restoreRoot.create(recursive: true);
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
        // IDs come from the archive; use a generated filename to prevent path traversal.
        final destination = File(p.join(destinationDir.path, '${_uuid.v4()}_$safeName'));
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

  Future<String?> verifyLatestPortableMetadataSnapshot() async {
    final locations = await StorageLocationService.instance.portableDataLocations();
    final children = await StorageLocationService.instance.listDirectory(locations['databaseUri']!);
    final snapshots = children
        .where((entry) => entry['isDirectory'] == true &&
            (entry['name'] as String).startsWith('snapshot_'))
        .toList()
      ..sort((a, b) => (b['name'] as String).compareTo(a['name'] as String));
    if (snapshots.isEmpty) return null;

    final snapshot = snapshots.first;
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
    return snapshot['name'] as String;
  }

  /// Restores the newest portable snapshot additively. Existing records are
  /// retained; imported IDs are remapped where needed. PDFs are relinked by
  /// SHA-256 from the currently selected library and are never overwritten.
  Future<Map<String, int>> restoreLatestPortableMetadataSnapshot() async {
    final storage = StorageLocationService.instance;
    final locations = await storage.portableDataLocations();
    final children = await storage.listDirectory(locations['databaseUri']!);
    final snapshots = children
        .where((entry) => entry['isDirectory'] == true &&
            (entry['name'] as String).startsWith('snapshot_'))
        .toList()
      ..sort((a, b) => (b['name'] as String).compareTo(a['name'] as String));
    if (snapshots.isEmpty) throw StateError('No portable recovery snapshot was found.');

    final snapshotUri = snapshots.first['uri'] as String;
    final manifestText = await storage.readTextFile(
      await _findChildUri(snapshotUri, 'manifest.json'),
    );
    final manifest = PortableSnapshotManifest.parse(manifestText);
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
    // Validate every ID, parent reference, path component and cycle before
    // creating any directory in the user's selected storage provider.
    final folderRows = rowsByTable['folders']!;
    final folderRowsById = PortableSnapshotManifest.validateFolderRows(folderRows);

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
    final folderIdMap = <String, String>{};
    final folderUriMap = <String, String>{};
    final matchedFolderIds = <String>{};
    Future<String> ensureFolder(String oldId, Set<String> visiting) async {
      final known = folderUriMap[oldId];
      if (known != null) return known;
      if (!visiting.add(oldId)) throw StateError('Snapshot folder hierarchy contains a cycle.');
      final row = folderRowsById[oldId];
      if (row == null) throw StateError('Snapshot refers to a missing parent folder.');
      final parentId = row['parent_id'] as String?;
      final parentUri = parentId == null
          ? locations['libraryUri']!
          : await ensureFolder(parentId, visiting);
      // Folder names were validated as safe path components before storage access.
      final rawName = row['name'] as String;
      final siblings = await storage.listDirectory(parentUri);
      final existing = siblings.where((entry) =>
          entry['isDirectory'] == true && entry['name'] == rawName);
      final uri = existing.isNotEmpty
          ? existing.first['uri'] as String
          : await storage.createDirectory(parentUri: parentUri, name: rawName);
      folderUriMap[oldId] = uri;
      final mappedParentId = parentId == null ? null : folderIdMap[parentId];
      final matchingFolder = existingFolders.where((candidate) =>
          candidate['name'] == rawName &&
          candidate['parent_id'] == mappedParentId &&
          candidate['deleted_at'] == null &&
          !matchedFolderIds.contains(candidate['id']));
      if (matchingFolder.isNotEmpty) {
        final existing = matchingFolder.first;
        folderIdMap[oldId] = existing['id'] as String;
        matchedFolderIds.add(existing['id'] as String);
      } else {
        folderIdMap[oldId] = _uuid.v4();
      }
      visiting.remove(oldId);
      return uri;
    }
    for (final row in folderRows) {
      await ensureFolder(row['id'] as String, <String>{});
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
        if (!insertedFolders.add(oldId)) return;
        final row = folderRowsById[oldId];
        if (row == null) throw StateError('Snapshot folder parent is missing.');
        final parentId = row['parent_id'] as String?;
        if (parentId != null) await insertFolder(parentId);
        final mappedId = folderIdMap[oldId]!;
        final values = {
          ...row,
          'id': mappedId,
          'parent_id': parentId == null ? null : folderIdMap[parentId],
          'storage_uri_or_relative_path': folderUriMap[oldId],
        };
        if (existingFolders.any((candidate) => candidate['id'] == mappedId)) {
          await txn.update('folders', {
            'storage_uri_or_relative_path': folderUriMap[oldId],
          }, where: 'id = ?', whereArgs: [mappedId]);
        } else {
          await txn.insert('folders', values, conflictAlgorithm: ConflictAlgorithm.ignore);
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
          ..['storage_uri'] = linkedUri;
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
    final decoded = ZipDecoder().decodeBytes(await zipFile.readAsBytes());
    final manifestFile = decoded.findFile('manifest.json');
    if (manifestFile == null || !manifestFile.isFile) {
      throw StateError('This is not a DocsGrid backup.');
    }
    final manifest = jsonDecode(utf8.decode(manifestFile.content as List<int>));
    if (manifest is! Map<String, dynamic> ||
        manifest['format'] != 'DocsGridBackup' || manifest['version'] != 1) {
      throw StateError('Unsupported backup format or version.');
    }

    final tableNames = <String>[
      'folders', 'documents', 'categories', 'tags', 'document_tags',
      'reminders', 'history', 'settings', 'document_text_index',
    ];
    final declaredTables = manifest['tables'];
    if (declaredTables is! Map<String, dynamic>) {
      throw StateError('Backup manifest is missing table counts.');
    }
    final rowsByTable = <String, List<dynamic>>{};
    for (final table in tableNames) {
      final archiveEntry = decoded.findFile('$table.json');
      if (archiveEntry == null && table == 'document_text_index') {
        rowsByTable[table] = <dynamic>[];
        continue;
      }
      if (archiveEntry == null || !archiveEntry.isFile) {
        throw StateError('Backup is incomplete: missing $table metadata.');
      }
      final rows = jsonDecode(utf8.decode(archiveEntry.content as List<int>));
      if (rows is! List) {
        throw StateError('Backup contains invalid $table metadata.');
      }
      final declaredCount = declaredTables[table];
      if (declaredCount != null && declaredCount != rows.length) {
        throw StateError('Backup metadata count mismatch for $table.');
      }
      if (declaredCount == null && table != 'document_text_index') {
        throw StateError('Backup manifest is missing the $table count.');
      }
      rowsByTable[table] = rows;
    }

    final rawFiles = manifest['files'];
    if (rawFiles is! List) {
      throw StateError('Backup manifest has an invalid PDF list.');
    }
    final documentIds = <String>{};
    final fileIds = <String>{};
    for (final raw in rawFiles) {
      if (raw is! Map<String, dynamic>) {
        throw StateError('Backup manifest contains an invalid PDF record.');
      }
      final id = raw['documentId'];
      final entryName = raw['entry'];
      final expectedDigest = raw['sha256'];
      if (id is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id) ||
          !fileIds.add(id)) {
        throw StateError('Backup contains a missing or duplicate document reference.');
      }
      final digestIsValid = expectedDigest is String &&
          expectedDigest.length == 64 &&
          expectedDigest.codeUnits.every((unit) =>
              (unit >= 48 && unit <= 57) ||
              (unit >= 65 && unit <= 70) ||
              (unit >= 97 && unit <= 102));
      if (entryName != 'pdfs/$id.pdf' || !digestIsValid) {
        throw StateError('Backup contains an invalid PDF entry reference.');
      }
      final entry = decoded.findFile(entryName as String);
      if (entry == null || !entry.isFile) {
        throw StateError('Backup is incomplete: missing PDF entry.');
      }
      final digest = sha256.convert(entry.content as List<int>).toString();
      if (digest != expectedDigest) {
        throw StateError('Backup integrity check failed.');
      }
      documentIds.add(id);
    }

    final metadataDocumentIds = <String>{};
    for (final row in rowsByTable['documents']!) {
      if (row is! Map || row['id'] is! String ||
          !metadataDocumentIds.add(row['id'] as String)) {
        throw StateError('Backup contains an invalid or duplicate document metadata record.');
      }
      if (!documentIds.contains(row['id'])) {
        throw StateError('Backup metadata references a document with no PDF.');
      }
    }
    if (metadataDocumentIds.length != documentIds.length ||
        !metadataDocumentIds.containsAll(documentIds)) {
      throw StateError('Backup contains orphaned PDF entries or missing document records.');
    }
    return rawFiles.length;
  }
}
