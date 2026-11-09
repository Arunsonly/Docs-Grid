import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/material.dart';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart' show InputFileStream, OutputFileStream, ZipFileEncoder;
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
import 'backup_folder_graph_validator.dart';
import 'document_crop_screen.dart';
import 'portable_snapshot_manifest.dart';
import 'portable_snapshot_rows_validator.dart';


/// Pure, isolate-safe OCR grouping. Input contains only SQLite scalar values;
/// this function never touches plugins, files, widgets, or database handles.
List<Map<String, Object?>> _groupOcrDuplicateRows(
  List<Map<String, Object?>> rows,
) {
  final groups = <String, List<Map<String, Object?>>>{};
  for (final row in rows) {
    final normalized = DocumentToolsService.normalizeDuplicateText(
      row['extracted_text']?.toString() ?? '',
    );
    if (normalized.length < 80) continue;
    final key = sha256.convert(utf8.encode(normalized)).toString();
    groups.putIfAbsent(key, () => []).add(row);
  }
  return groups.entries
      .where((entry) => entry.value.length > 1)
      .map((entry) => <String, Object?>{
            'group_key': entry.key,
            'duplicate_type': 'OCR text',
            'copies': entry.value.length,
            'document_ids': entry.value.map((row) => row['id']).join(','),
            'names': entry.value.map((row) => row['name']).join(' | '),
          })
      .toList();
}

/// Local-only utilities for indexing, scanning, sharing and portable backups.
/// This service never uploads document contents to a remote server.
class DocumentToolsService {
  DocumentToolsService({AppDatabase? database})
      : _database = database ?? AppDatabase.instance;

  final AppDatabase _database;
  static const _uuid = Uuid();

  /// Hashes untrusted IDs before using them as restore path segments.
  @visibleForTesting
  static String safeRestorePathToken(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  /// Escapes text for a literal SQLite LIKE substring query.
  @visibleForTesting
  static String escapeLikeQuery(String value) {
    final slash = String.fromCharCode(92);
    return value
        .replaceAll(slash, '$slash$slash')
        .replaceAll('%', '$slash%')
        .replaceAll('_', '${slash}_');
  }
  static final Set<String> _indexingDocumentIds = <String>{};

  /// Normalizes OCR text for exact-content duplicate comparison.
  /// Keeps letters and numbers from all scripts, including Devanagari.
  @visibleForTesting
  static String normalizeDuplicateText(String raw) => raw
      .toLowerCase()
      .replaceAll(RegExp(r'--- page \d+ ---', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');

  /// Finds exact file duplicates and OCR-text duplicates locally.
  Future<List<Map<String, Object?>>> findDuplicateGroups() async {
    final db = await _database.database;
    final exact = await _verifiedExactDuplicateGroups();
    final indexed = await db.rawQuery('''
      SELECT d.id, d.name, i.extracted_text
      FROM documents d JOIN document_text_index i ON i.document_id = d.id
      WHERE d.deleted_at IS NULL AND i.extracted_text IS NOT NULL
    ''');
    // OCR text normalization and digest grouping are CPU-bound pure Dart
    // work. Run them off the UI isolate; database and platform file access
    // remain on the main isolate and are completed before this hand-off.
    final ocr = await Isolate.run(() => _groupOcrDuplicateRows(indexed));
    final groups = <Map<String, Object?>>[...exact, ...ocr];
    groups.sort((a, b) => (b['copies'] as int).compareTo(a['copies'] as int));
    return groups;
  }

  Future<List<Map<String, Object?>>> _verifiedExactDuplicateGroups() async {
    final db = await _database.database;
    final documents = await db.query(
      'documents',
      columns: ['id', 'name', 'storage_uri', 'sha256'],
      where: 'deleted_at IS NULL',
      orderBy: 'created_at ASC',
    );
    final groups = <String, List<Map<String, Object?>>>{};
    for (final document in documents) {
      final uri = document['storage_uri'] as String?;
      if (uri == null || uri.isEmpty) continue;
      try {
        final digest = uri.startsWith('content://') || uri.startsWith('file://')
            ? await StorageLocationService.instance.sha256Pdf(uri)
            : (await sha256.bind(File(uri).openRead()).first).toString();
        if (digest != document['sha256']) {
          await db.update(
            'documents',
            {'sha256': digest, 'updated_at': DateTime.now().toUtc().toIso8601String()},
            where: 'id = ? AND deleted_at IS NULL',
            whereArgs: [document['id']],
          );
        }
        groups.putIfAbsent(digest, () => []).add(document);
      } catch (_) {
        // Missing or inaccessible PDFs are not treated as verified duplicates.
      }
    }
    return groups.entries
        .where((entry) => entry.value.length > 1)
        .map((entry) => <String, Object?>{
          'group_key': entry.key,
          'duplicate_type': 'SHA-256',
          'copies': entry.value.length,
          'document_ids': entry.value.map((row) => row['id']).join(','),
          'names': entry.value.map((row) => row['name']).join(' | '),
          'sha256': entry.key,
        })
        .toList()
      ..sort((a, b) => (b['copies'] as int).compareTo(a['copies'] as int));
  }

  Future<List<Map<String, Object?>>> findExactDuplicates() async =>
      _verifiedExactDuplicateGroups();

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
    if (!_indexingDocumentIds.add(documentId)) {
      throw StateError('This document is already being indexed.');
    }
    try {
      final db = await _database.database;
      final previousIndex = await db.query(
        'document_text_index',
        columns: ['document_id'],
        where: 'document_id = ?',
        whereArgs: [documentId],
        limit: 1,
      );
      try {
        await db.update(
          'documents',
          {'extracted_text_status': 'indexing'},
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [documentId],
        );
        return await _indexPdfTextInternal(documentId, path);
      } catch (_) {
        // Keep an older successful index usable if a re-index attempt fails.
        try {
          await db.update(
            'documents',
            {'extracted_text_status': previousIndex.isEmpty ? 'failed' : 'indexed'},
            where: 'id = ? AND deleted_at IS NULL',
            whereArgs: [documentId],
          );
        } catch (_) {
          // Preserve the original OCR failure if status recovery also fails.
        }
        rethrow;
      }
    } finally {
      _indexingDocumentIds.remove(documentId);
    }
  }

  Future<int> _indexPdfTextInternal(String documentId, String path) async {
    final db = await _database.database;
    final documentRows = await db.query(
      'documents',
      columns: ['id'],
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [documentId],
      limit: 1,
    );
    if (documentRows.isEmpty) throw StateError('Document no longer exists in the library.');
    final file = File(path);
    if (!await file.exists()) throw StateError('PDF is not available on this device.');
    final header = await file.openRead(0, 5).fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    if (header.length < 5 || String.fromCharCodes(header) != '%PDF-') {
      throw StateError('The selected file is not a valid PDF.');
    }
    final document = await pdfx.PdfDocument.openFile(path);
    final pageCount = document.pagesCount;
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    TextRecognizer? devanagariRecognizer;
    final pages = StringBuffer();
    try {
      if (Platform.isAndroid) {
        devanagariRecognizer = TextRecognizer(script: TextRecognitionScript.devanagiri);
      }
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
          try {
            await image.writeAsBytes(rendered.bytes, flush: true);
            final input = InputImage.fromFilePath(image.path);
            final latinResult = await recognizer.processImage(input);
            final extracted = <String>[latinResult.text];
            if (devanagariRecognizer != null) {
              final devanagariResult = await devanagariRecognizer.processImage(input);
              if (devanagariResult.text.isNotEmpty) extracted.add(devanagariResult.text);
            }
            final pageText = extracted.where((value) => value.trim().isNotEmpty).join('\n');
            pages.write('--- Page $pageNumber ---\n$pageText\n\n');
          } finally {
            if (await image.exists()) await image.delete();
          }
        } finally {
          await page.close();
        }
      }
    } finally {
      await recognizer.close();
      await devanagariRecognizer?.close();
      await document.close();
    }
    final text = pages.toString().trim();
    await db.transaction((txn) async {
      await txn.insert('document_text_index', {
        'document_id': documentId,
        'extracted_text': text,
        'indexed_at': DateTime.now().toUtc().toIso8601String(),
        'page_count': pageCount,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.update(
        'documents',
        {'extracted_text_status': text.isEmpty ? 'empty' : 'indexed'},
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [documentId],
      );
    });
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
      WHERE d.deleted_at IS NULL
        AND instr(lower(i.extracted_text), lower(?)) > 0
      ORDER BY match_position ASC, d.name COLLATE NOCASE
    ''', [q, q]);
    // sqflite may return immutable QueryRow instances. Copy each result before
    // enriching it with the resolved OCR page number.
    final results = rows.map((row) => Map<String, Object?>.from(row)).toList();
    // OCR stores an explicit page marker before every page. Resolve the page
    // containing the first match so search results are actionable, not just a
    // generic "text found" indication.
    for (final row in results) {
      final text = row['extracted_text']?.toString() ?? '';
      final position = (row['match_position'] as int? ?? 1) - 1;
      final prefix = text.substring(0, position.clamp(0, text.length));
      final markers = RegExp(r'--- Page (\d+) ---').allMatches(prefix).toList();
      row['match_page'] = markers.isEmpty ? 1 : int.parse(markers.last.group(1)!);
    }
    return results;
  }

  Future<File?> scanToPdf({
    required BuildContext context,
    bool useCamera = false,
  }) async {
    final picker = ImagePicker();
    var selected = <XFile>[];
    if (useCamera) {
      // Capture a page at a time, allowing a multi-page document without
      // requiring the user to leave the scanner and start a new PDF.
      while (context.mounted) {
        final image = await picker.pickImage(
          source: ImageSource.camera,
          imageQuality: 95,
        );
        if (image == null) break;
        selected.add(image);
        if (!context.mounted) return null;
        final addAnother = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('Page ${selected.length} captured'),
            content: const Text('Would you like to scan another page into this PDF?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Finish'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Scan next page'),
              ),
            ],
          ),
        );
        if (!context.mounted) return null;
        if (addAnother != true) break;
      }
    } else {
      selected = await picker.pickMultiImage(imageQuality: 95);
    }
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
              height: 190,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Drag thumbnails to change page order.'),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ReorderableListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: ordered.length,
                      onReorderItem: (oldIndex, newIndex) {
                        refresh(() {
                          final item = ordered.removeAt(oldIndex);
                          ordered.insert(newIndex, item);
                        });
                      },
                      itemBuilder: (context, index) => SizedBox(
                        key: ValueKey(ordered[index].path),
                        width: 112,
                        child: Card(
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            children: [
                              Expanded(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Image.file(
                                      File(ordered[index].path),
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => const ColoredBox(
                                        color: Colors.black12,
                                        child: Icon(Icons.image_not_supported_outlined),
                                      ),
                                    ),
                                    Positioned(
                                      left: 4,
                                      top: 4,
                                      child: CircleAvatar(
                                        radius: 12,
                                        child: Text('${index + 1}',
                                            style: const TextStyle(fontSize: 11)),
                                      ),
                                    ),
                                    const Positioned(
                                      right: 4,
                                      bottom: 4,
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: Color(0xAA000000),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Padding(
                                          padding: EdgeInsets.all(5),
                                          child: Icon(Icons.drag_indicator,
                                              color: Colors.white, size: 18),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(4),
                                child: Text(
                                  ordered[index].name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 10),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
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
    final processedPaths = <String>{};
    while (processedPaths.length < selected.length) {
      // Re-read the first unprocessed item after every crop. The crop screen
      // can reorder the persistent filmstrip while the current page remains
      // active; the next page follows the newly selected order.
      final image = selected.firstWhere((item) => !processedPaths.contains(item.path));
      final originalBytes = await image.readAsBytes();
      if (!context.mounted) return null;
      final croppedBytes = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(
          builder: (_) => DocumentCropScreen(
            imageBytes: originalBytes,
            pagePaths: selected.map((item) => item.path).toList(growable: false),
            onReorderPages: (orderedPaths) {
              final byPath = {for (final item in selected) item.path: item};
              selected = orderedPaths.map((path) => byPath[path])
                  .whereType<XFile>().toList(growable: true);
            },
          ),
          fullscreenDialog: true,
        ),
      );
      if (croppedBytes == null) return null;
      processedPaths.add(image.path);
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
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final file = File(p.join(scans.path, 'Scan_$stamp.pdf'));
    final partial = File('${file.path}.partial');
    try {
      // Write to a staging file first. A failed encode/write must never leave a
      // truncated PDF that looks like a successfully exported scan.
      final bytes = await pdf.save();
      if (bytes.length < 8 ||
          String.fromCharCodes(bytes.take(5)) != '%PDF-') {
        throw StateError('PDF encoder returned an invalid document.');
      }
      await partial.writeAsBytes(bytes, flush: true);
      final writtenHeader = await partial.openRead(0, 5)
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      if (writtenHeader.length != 5 ||
          String.fromCharCodes(writtenHeader) != '%PDF-') {
        throw StateError('Exported PDF failed its header verification.');
      }
      final verification = await pdfx.PdfDocument.openFile(partial.path);
      try {
        if (verification.pagesCount != selected.length) {
          throw StateError('Exported PDF page count does not match the selected images.');
        }
      } finally {
        await verification.close();
      }
      await partial.rename(file.path);
      return file;
    } catch (_) {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      rethrow;
    }
  }


  Future<void> shareStoredPdf(String storageUri, String displayName) async {
    File? stagedProviderFile;
    try {
      String path;
      if (storageUri.startsWith('content://') || storageUri.startsWith('file://')) {
        final temp = await getTemporaryDirectory();
        final safeName = p.basename(displayName).replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
        stagedProviderFile = File(p.join(temp.path, 'share_${_uuid.v4()}_$safeName'));
        await StorageLocationService.instance.copyPdfToPath(
          sourceUri: storageUri,
          destinationPath: stagedProviderFile.path,
        );
        path = stagedProviderFile.path;
      } else {
        path = storageUri.startsWith('file://') ? Uri.parse(storageUri).toFilePath() : storageUri;
      }
      final file = File(path);
      if (!await file.exists()) throw StateError('PDF is no longer available to share.');
      await SharePlus.instance.share(ShareParams(files: [XFile(path)], text: displayName));
    } finally {
      // Provider PDFs are copied into cache because share_plus needs a local
      // path. Remove only that temporary copy after the native share sheet ends.
      if (stagedProviderFile != null) {
        try {
          if (await stagedProviderFile.exists()) await stagedProviderFile.delete();
        } catch (_) {
          // Cache cleanup must not mask the share result or affect the source PDF.
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
    final files = <XFile>[];
    final stagedFiles = <File>[];
    try {
      for (var i = 0; i < storageUris.length; i++) {
        final uri = storageUris[i];
        final safeName = p.basename(displayNames[i]).replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
        String path;
        if (uri.startsWith('content://') || uri.startsWith('file://')) {
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
    final tables = ['folders', 'documents', 'categories', 'tags',
      'document_tags', 'reminders', 'history', 'settings', 'document_text_index'];
    final manifest = <String, Object?>{
      'format': 'DocsGridBackup',
      'version': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'tables': <String, int>{},
      'files': <Map<String, Object?>>[],
    };

    final directory = await getApplicationDocumentsDirectory();
    final backups = Directory(p.join(directory.path, 'DocsGrid', 'Backups'));
    await backups.create(recursive: true);
    final temp = await getTemporaryDirectory();
    final staging = await temp.createTemp('docsgrid_backup_');
    final output = File(p.join(
      backups.path,
      'DocsGrid_${DateTime.now().toUtc().millisecondsSinceEpoch}_${_uuid.v4()}.zip',
    ));
    final encoder = ZipFileEncoder();
    var encoderOpened = false;
    Future<void> addStoredFile(File file, String archiveName) async {
      final input = InputFileStream(file.path);
      try {
        final entry = ArchiveFile.stream(archiveName, input)
          ..compression = CompressionType.none;
        encoder.addArchiveFile(entry);
      } finally {
        await input.close();
      }
    }
    try {
      encoder.create(output.path);
      encoderOpened = true;

      // Page database rows into JSON files so a large history/documents table
      // does not have to be materialized as one giant List in memory.
      const orderBy = <String, String>{
        'folders': 'id',
        'documents': 'id',
        'categories': 'id',
        'tags': 'id',
        'document_tags': 'document_id, tag_id',
        'reminders': 'id',
        'history': 'id',
        'settings': 'key',
        'document_text_index': 'document_id',
      };
      for (final table in tables) {
        final metadataFile = File(p.join(staging.path, '$table.json'));
        final outputFile = await metadataFile.open(mode: FileMode.write);
        var offset = 0;
        var rowCount = 0;
        try {
          await outputFile.writeString('[');
          while (true) {
            final rows = await db.query(
              table,
              limit: 500,
              offset: offset,
              orderBy: orderBy[table],
            );
            if (rows.isEmpty) break;
            for (final row in rows) {
              if (rowCount > 0) await outputFile.writeString(',');
              await outputFile.writeString(jsonEncode(row), encoding: utf8);
              rowCount++;
            }
            offset += rows.length;
          }
          await outputFile.writeString(']');
          await outputFile.flush();
        } finally {
          await outputFile.close();
        }
        (manifest['tables'] as Map<String, int>)[table] = rowCount;
        await addStoredFile(metadataFile, '$table.json');
      }

      final totalDocs = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) FROM documents'),
      ) ?? 0;
      var completed = 0;
      var documentOffset = 0;
      while (true) {
        final docs = await db.query(
          'documents',
          columns: ['id', 'name', 'storage_uri', 'sha256'],
          limit: 250,
          offset: documentOffset,
          orderBy: 'id',
        );
        if (docs.isEmpty) break;
        for (final row in docs) {
        final uri = row['storage_uri'] as String?;
        if (uri == null || uri.isEmpty) {
          throw StateError('Backup cannot be complete: "${row['name']}" has no storage reference.');
        }
        File? stagedProviderFile;
        final File file;
        if (uri.startsWith('content://')) {
          stagedProviderFile = File(p.join(staging.path, 'source_${_uuid.v4()}.pdf'));
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
          final digest = (await sha256.bind(file.openRead()).first).toString();
          final expected = row['sha256'] as String?;
          if (expected != null && expected.isNotEmpty && digest != expected) {
            throw StateError('Backup stopped: "${row['name']}" failed SHA-256 verification.');
          }
          // Never place imported database IDs in archive paths.
          final entry = 'pdfs/${_uuid.v4()}.pdf';
          // Stream already-compressed PDF bytes directly into the ZIP without
          // allocating a second full-size buffer or recompressing the payload.
          await addStoredFile(file, entry);
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
          onProgress?.call(completed, totalDocs);
        }
        documentOffset += docs.length;
      }

      final manifestFile = File(p.join(staging.path, 'manifest.json'));
      await manifestFile.writeAsString(jsonEncode(manifest), encoding: utf8, flush: true);
      await addStoredFile(manifestFile, 'manifest.json');
      await encoder.close();
      encoderOpened = false;
      await BackupArchiveLimits.validate(output);
      return output;
    } catch (_) {
      if (encoderOpened) {
        try { await encoder.close(); } catch (_) {}
      }
      try { if (await output.exists()) await output.delete(); } catch (_) {}
      rethrow;
    } finally {
      try { if (await staging.exists()) await staging.delete(recursive: true); } catch (_) {}
    }
  }

  /// Additively restores a verified archive. Existing document/folder IDs are
  /// never overwritten; any collision aborts the database transaction.
  /// Additively restores a verified archive. Existing document/folder IDs are
  /// never overwritten; any collision aborts the database transaction.
  Future<int> restoreBackup(File zipFile) async {
    final backup = await _decodeValidatedBackup(zipFile);
    try {
      return await _restoreValidatedBackup(backup);
    } finally {
      await backup.dispose();
    }
  }

  Future<int> _restoreValidatedBackup(_ValidatedBackup backup) async {
    final manifest = backup.manifest;
    final rowsByTable = backup.rowsByTable;
    final folderRows = rowsByTable['folders']!;
    final folderRowsById = <String, Map<String, Object?>>{
      for (final row in folderRows) row['id'] as String: row,
    };
    final documentsById = <String, Map<String, Object?>>{
      for (final row in rowsByTable['documents']!) row['id'] as String: row,
    };
    // A ZIP is untrusted input. Validate parent links before creating any
    // directories, and never use imported IDs as filesystem path segments.
    BackupFolderGraphValidator.validate(folderRows);
    PortableSnapshotRowsValidator.validate(rowsByTable);
    final root = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'DocsGrid', 'Restored'));
    final restoreRoot = Directory(p.join(root.path, DateTime.now().microsecondsSinceEpoch.toString()));
    await restoreRoot.create(recursive: true);
    final fileRows = (manifest['files'] as List<dynamic>).cast<Map<String, dynamic>>();
    final restoredPaths = <String, String>{};
    final folderPaths = <String, String>{};
    final folderDirectoryNames = <String, String>{
      for (final row in folderRows) (row['id'] as String): 'folder_${_uuid.v4()}',
    };
    String folderPath(String id) {
      final known = folderPaths[id];
      if (known != null) return known;
      final unresolved = <String>[];
      String? current = id;
      while (current != null && !folderPaths.containsKey(current)) {
        unresolved.add(current);
        final row = folderRowsById[current];
        if (row == null) throw StateError('Backup contains an unknown folder reference.');
        current = row['parent_id'] as String?;
      }
      var base = current == null ? restoreRoot.path : folderPaths[current]!;
      for (final folderId in unresolved.reversed) {
        base = p.join(base, folderDirectoryNames[folderId]!);
        folderPaths[folderId] = base;
      }
      return folderPaths[id]!;
    }

    var databaseCommitted = false;
    try {
      for (final row in folderRows) {
        await Directory(folderPath(row['id'] as String)).create(recursive: true);
      }
      for (final item in fileRows) {
        final id = item['documentId'] as String;
        final document = documentsById[id];
        if (document == null) throw StateError('Backup contains an unknown document reference.');
        final folderId = document['folder_id'] as String?;
        final destinationDir = folderId == null ? restoreRoot : Directory(folderPath(folderId));
        await destinationDir.create(recursive: true);
        final requestedName = p.basename((item['originalName'] as String?) ?? 'document.pdf')
            .replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_')
            .replaceAll('/', '_')
            .replaceAll('\\', '_')
            .trim();
        final safeName = requestedName.isEmpty
            ? 'document.pdf'
            : String.fromCharCodes(requestedName.runes.take(120));
        // Use a fresh local filename; imported document IDs are database keys,
        // not trusted path components.
        final destination = File(p.join(destinationDir.path, '${_uuid.v4()}_$safeName'));
        final stagedPath = backup.stagedPdfPaths[id];
        if (stagedPath == null) throw StateError('Backup is missing staged PDF bytes.');
        await File(stagedPath).copy(destination.path);
        final digest = (await sha256.bind(destination.openRead()).first).toString();
        if (digest != item['sha256']) {
          await destination.delete();
          throw StateError('PDF integrity check failed during restore.');
        }
        restoredPaths[id] = destination.path;
      }

      final db = await _database.database;
      await db.transaction((txn) async {
        var batch = txn.batch();
        var pending = 0;
        Future<void> flushBatch() async {
          if (pending == 0) return;
          await batch.commit(noResult: true);
          batch = txn.batch();
          pending = 0;
        }
        void queueInsert(
          String table,
          Map<String, Object?> row, {
          ConflictAlgorithm? conflictAlgorithm,
        }) {
          batch.insert(table, row, conflictAlgorithm: conflictAlgorithm);
          pending++;
        }

        for (final row in folderRows) {
          final copy = Map<String, Object?>.from(row);
          copy['storage_uri_or_relative_path'] = folderPath(row['id'] as String);
          queueInsert('folders', copy);
          if (pending >= 500) await flushBatch();
        }
        // Additive restore maps categories/tags by case-insensitive name.
        // Never silently ignore a conflicting ID and leave document references
        // pointing at a different or missing category/tag.
        final existingCategories = await txn.query('categories', columns: ['id', 'name']);
        final existingTags = await txn.query('tags', columns: ['id', 'name']);
        final categoryIdMap = <String, String>{};
        final tagIdMap = <String, String>{};
        final existingCategoryIds = existingCategories.map((row) => row['id'] as String).toSet();
        final existingTagIds = existingTags.map((row) => row['id'] as String).toSet();
        for (final row in rowsByTable['categories']!) {
          final oldId = row['id'] as String;
          final name = row['name'] as String;
          final sameName = existingCategories.where((item) =>
            (item['name'] as String).toLowerCase() == name.toLowerCase());
          final mappedId = sameName.isNotEmpty
              ? sameName.first['id'] as String
              : (existingCategoryIds.contains(oldId) ? _uuid.v4() : oldId);
          categoryIdMap[oldId] = mappedId;
          if (!existingCategoryIds.contains(mappedId)) {
            queueInsert('categories', {...row, 'id': mappedId});
            existingCategoryIds.add(mappedId);
          }
          if (pending >= 500) await flushBatch();
        }
        for (final row in rowsByTable['tags']!) {
          final oldId = row['id'] as String;
          final name = row['name'] as String;
          final sameName = existingTags.where((item) =>
            (item['name'] as String).toLowerCase() == name.toLowerCase());
          final mappedId = sameName.isNotEmpty
              ? sameName.first['id'] as String
              : (existingTagIds.contains(oldId) ? _uuid.v4() : oldId);
          tagIdMap[oldId] = mappedId;
          if (!existingTagIds.contains(mappedId)) {
            queueInsert('tags', {...row, 'id': mappedId});
            existingTagIds.add(mappedId);
          }
          if (pending >= 500) await flushBatch();
        }
        for (final row in rowsByTable['documents']!) {
          final copy = Map<String, Object?>.from(row);
          final oldCategoryId = row['category_id'] as String?;
          copy['category_id'] = oldCategoryId == null ? null : categoryIdMap[oldCategoryId];
          final restored = restoredPaths[row['id']];
          if (restored == null) throw StateError('Backup is missing PDF bytes for "${row['name']}".');
          copy['storage_uri'] = restored;
          queueInsert('documents', copy);
          if (pending >= 500) await flushBatch();
        }
        for (final row in rowsByTable['document_tags']!) {
          final oldTagId = row['tag_id'] as String;
          final mappedTagId = tagIdMap[oldTagId];
          if (mappedTagId == null) throw StateError('Backup contains an unknown tag reference.');
          queueInsert('document_tags', {...row, 'tag_id': mappedTagId});
          if (pending >= 500) await flushBatch();
        }
        for (final table in ['reminders', 'history', 'document_text_index']) {
          for (final row in rowsByTable[table]!) {
            queueInsert(table, row);
            if (pending >= 500) await flushBatch();
          }
        }
        // Preferences are additive: never overwrite settings already configured
        // on this device when importing a backup from another installation.
        for (final row in rowsByTable['settings']!) {
          queueInsert('settings', row, conflictAlgorithm: ConflictAlgorithm.ignore);
          if (pending >= 500) await flushBatch();
        }
        await flushBatch();
      });
      databaseCommitted = true;
      for (final row in rowsByTable['reminders']!) {
        if ((row['enabled'] as int? ?? 0) != 1 || row['status'] == 'completed') continue;
        try {
          final at = DateTime.parse(row['remind_at_utc'] as String).toLocal();
          await ReminderNotifications.instance.schedule(
            id: row['id'] as String,
            title: row['title'] as String,
            body: row['note'] as String?,
            at: at,
            recurrence: row['recurrence_rule'] as String?,
            documentId: row['document_id'] as String?,
          );
        } catch (_) {
          // Imported records remain valid even if dates or OS scheduling fail.
        }
      }
      return restoredPaths.length;
    } catch (_) {
      if (!databaseCommitted && await restoreRoot.exists()) {
        try { await restoreRoot.delete(recursive: true); } catch (_) {}
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

  /// Returns the newest fully verified snapshot, skipping incomplete or
  /// damaged snapshots left by an interrupted export. A broken newest folder
  /// must not hide an older recoverable snapshot.
  Future<Map<String, Object?>?> _findLatestVerifiedPortableSnapshot() async {
    final storage = StorageLocationService.instance;
    final locations = await storage.portableDataLocations();
    final children = await storage.listDirectory(locations['databaseUri']!);
    final snapshots = children
        .where((entry) => entry['isDirectory'] == true &&
            entry['name'] is String &&
            (entry['name'] as String).startsWith('snapshot_'))
        .toList()
      ..sort((a, b) => (b['name'] as String).compareTo(a['name'] as String));

    for (final snapshot in snapshots) {
      try {
        final snapshotUri = snapshot['uri'] as String;
        final manifestText = await storage.readTextFile(
          await _findChildUri(snapshotUri, 'manifest.json'),
        );
        final manifest = PortableSnapshotManifest.parse(manifestText);
        final rowsByTable = <String, List<Map<String, Object?>>>{};
        for (final record in manifest.files) {
          final table = record.path.substring(0, record.path.length - 5);
          if (!const {
            'folders', 'documents', 'categories', 'tags', 'document_tags',
            'reminders', 'history', 'settings', 'document_text_index',
            'schema_migrations',
          }.contains(table)) {
            throw StateError('Snapshot contains unsupported table: $table.');
          }
          final uri = await _findChildUri(snapshotUri, record.path);
          final contents = await storage.readTextFile(uri);
          final bytes = utf8.encode(contents);
          if (bytes.length != record.sizeBytes ||
              sha256.convert(bytes).toString() != record.sha256) {
            throw StateError('Recovery snapshot verification failed for ${record.path}.');
          }
          final decoded = jsonDecode(contents);
          if (decoded is! List || decoded.length != record.recordCount ||
              decoded.any((row) => row is! Map)) {
            throw StateError('Recovery snapshot record count or row shape is invalid for ${record.path}.');
          }
          rowsByTable[table] = decoded
              .map((row) => Map<String, Object?>.from(row as Map))
              .toList();
        }

        final folderRows = rowsByTable['folders'];
        final documentRows = rowsByTable['documents'];
        if (folderRows == null || documentRows == null) {
          throw StateError('Recovery snapshot is missing core metadata.');
        }
        final foldersById = PortableSnapshotManifest.validateFolderRows(folderRows);
        final documentIds = <String>{};
        for (final row in documentRows) {
          final id = row['id'];
          final folderId = row['folder_id'];
          if (id is! String || id.trim().isEmpty || id != id.trim() ||
              !documentIds.add(id)) {
            throw StateError('Recovery snapshot contains an invalid or duplicate document ID.');
          }
          if (folderId != null &&
              (folderId is! String || !foldersById.containsKey(folderId))) {
            throw StateError('Recovery snapshot references a missing folder.');
          }
        }
        Set<String> uniqueSnapshotIds(String table) {
          final ids = <String>{};
          for (final row in rowsByTable[table] ?? const <Map<String, Object?>>[]) {
            final id = row['id'];
            if (id is! String || id.trim().isEmpty || !ids.add(id)) {
              throw StateError('Snapshot contains an invalid or duplicate $table ID.');
            }
          }
          return ids;
        }

        final categoryIds = uniqueSnapshotIds('categories');
        final tagIds = uniqueSnapshotIds('tags');
        uniqueSnapshotIds('reminders');
        uniqueSnapshotIds('history');
        for (final row in documentRows) {
          final categoryId = row['category_id'];
          if (categoryId != null &&
              (categoryId is! String || !categoryIds.contains(categoryId))) {
            throw StateError('Snapshot document references a missing category.');
          }
        }
        final tagLinks = <String>{};
        for (final row in rowsByTable['document_tags'] ?? const <Map<String, Object?>>[]) {
          final documentId = row['document_id'];
          final tagId = row['tag_id'];
          if (documentId is! String || !documentIds.contains(documentId) ||
              tagId is! String || !tagIds.contains(tagId) ||
              !tagLinks.add(jsonEncode([documentId, tagId]))) {
            throw StateError('Snapshot contains an invalid or duplicate document-tag link.');
          }
        }
        for (final table in ['reminders', 'history']) {
          for (final row in rowsByTable[table] ?? const <Map<String, Object?>>[]) {
            final documentId = row['document_id'];
            if (documentId != null &&
                (documentId is! String || !documentIds.contains(documentId))) {
              throw StateError('Snapshot $table record references a missing document.');
            }
          }
        }
        for (final row in rowsByTable['document_text_index'] ?? const <Map<String, Object?>>[]) {
          if (row['document_id'] is! String ||
              !documentIds.contains(row['document_id'])) {
            throw StateError('Snapshot text index references a missing document.');
          }
        }
        final settingKeys = <String>{};
        for (final row in rowsByTable['settings'] ?? const <Map<String, Object?>>[]) {
          final key = row['key'];
          if (key is! String || key.isEmpty || !settingKeys.add(key)) {
            throw StateError('Snapshot contains an invalid or duplicate setting key.');
          }
        }

        return {
          'name': snapshot['name'] as String,
          'uri': snapshotUri,
          'manifestText': manifestText,
          'manifest': manifest,
        };
      } catch (_) {
        // Try the next older snapshot. Never mutate or delete a failed copy.
      }
    }
    return null;
  }

  Future<String?> verifyLatestPortableMetadataSnapshot() async {
    final snapshot = await _findLatestVerifiedPortableSnapshot();
    return snapshot?['name'] as String?;
  }

  /// Restores the newest portable snapshot additively. Existing records are
  /// retained; imported IDs are remapped where needed. PDFs are relinked by
  /// SHA-256 from the currently selected library and are never overwritten.
  Future<Map<String, int>> restoreLatestPortableMetadataSnapshot() async {
    final storage = StorageLocationService.instance;
    final locations = await storage.portableDataLocations();
    final snapshot = await _findLatestVerifiedPortableSnapshot();
    if (snapshot == null) {
      throw StateError('No complete, verified portable recovery snapshot was found.');
    }
    final snapshotUri = snapshot['uri'] as String;
    final manifest = snapshot['manifest'] as PortableSnapshotManifest;
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
    final seenDocumentIds = <String>{};
    for (final row in rowsByTable['documents']!) {
      final id = row['id'];
      final folderId = row['folder_id'];
      if (id is! String || id.trim().isEmpty || id != id.trim() ||
          !seenDocumentIds.add(id)) {
        throw const FormatException('Snapshot contains an invalid or duplicate document ID.');
      }
      if (folderId != null &&
          (folderId is! String || !folderRowsById.containsKey(folderId))) {
        throw const FormatException('Snapshot document references a missing folder.');
      }
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
    final folderIdMap = <String, String>{};
    final folderUriMap = <String, String>{};
    final createdFolderUris = <String>[];
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
      final alreadyExists = existing.isNotEmpty;
      final uri = alreadyExists
          ? existing.first['uri'] as String
          : await storage.createDirectory(parentUri: parentUri, name: rawName);
      if (!alreadyExists) createdFolderUris.add(uri);
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
    final reminderIdMap = <String, String>{};
    // Needed after the preflight/transaction block to attach notification
    // payloads to the remapped document IDs.
    final documentIdMap = <String, String>{};
    var addedDocuments = 0;
    var linkedDocuments = 0;
    var missingPdfs = 0;
    Future<void> rollbackCreatedFolders() async {
      for (final uri in createdFolderUris.reversed) {
        try {
          // Never remove a folder that acquired user content during restore.
          if ((await storage.listDirectory(uri)).isEmpty) {
            await storage.deletePdf(uri);
          }
        } catch (_) {
          // Keep any uncertain provider data rather than risking user files.
        }
      }
    }
    try {
      for (final row in folderRows) {
        await ensureFolder(row['id'] as String, <String>{});
      }

    final categoryIdMap = <String, String>{};
    final tagIdMap = <String, String>{};
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
    } catch (_) {
      await rollbackCreatedFolders();
      rethrow;
    }

    for (final row in rowsByTable['reminders']!) {
      if ((row['enabled'] as int? ?? 0) != 1 || row['status'] == 'completed') continue;
      try {
        await ReminderNotifications.instance.schedule(
          id: reminderIdMap[row['id']]!,
          title: row['title'] as String,
          body: row['note'] as String?,
          at: DateTime.parse(row['remind_at_utc'] as String).toLocal(),
          recurrence: row['recurrence_rule'] as String?,
          documentId: row['document_id'] == null
              ? null
              : documentIdMap[row['document_id']],
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
    final backup = await _decodeValidatedBackup(zipFile);
    try {
      return (backup.manifest['files'] as List<dynamic>).length;
    } finally {
      await backup.dispose();
    }
  }

  Future<_ValidatedBackup> _decodeValidatedBackup(File zipFile) async {
    if (!await zipFile.exists()) throw StateError('Backup file not found.');
    try {
      await BackupArchiveLimits.validate(zipFile);
    } on FormatException catch (error) {
      throw StateError(error.message);
    }
    final input = InputFileStream(zipFile.path);
    Directory? staging;
    try {
      final decoded = ZipDecoder().decodeStream(input);
      final archiveNames = <String>{};
      for (final entry in decoded.files) {
        final name = entry.name;
        final segments = name.split('/');
        if (!entry.isFile || entry.isSymbolicLink || name.isEmpty ||
            name.startsWith('/') || name.contains('\\\\') ||
            name.codeUnits.any((unit) => unit < 32 || unit == 127) ||
            segments.any((part) => part.isEmpty || part == '.' || part == '..') ||
            !archiveNames.add(name)) {
          throw StateError('Backup contains an unsafe, duplicate, or unsupported ZIP entry.');
        }
      }
      final manifestFile = decoded.findFile('manifest.json');
      if (manifestFile == null) throw StateError('This is not a DocsGrid backup.');
      final manifestValue = jsonDecode(utf8.decode(manifestFile.content as List<int>));
      if (manifestValue is! Map<String, dynamic> ||
          manifestValue['format'] != 'DocsGridBackup' ||
          manifestValue['version'] != 1) {
        throw StateError('Unsupported backup format or version.');
      }
      final manifest = manifestValue;
      final declaredTables = manifest['tables'];
      if (declaredTables is! Map<String, dynamic>) {
        throw StateError('Backup manifest is missing table counts.');
      }
      final documentsFile = decoded.findFile('documents.json');
      if (documentsFile == null) {
        throw StateError('Backup is incomplete: missing documents metadata.');
      }
      final rawDocuments = jsonDecode(utf8.decode(documentsFile.content as List<int>));
      if (rawDocuments is! List) throw StateError('Backup document metadata is invalid.');
      final documentIds = <String>{};
      for (final raw in rawDocuments) {
        if (raw is! Map || raw['id'] is! String ||
            (raw['id'] as String).trim().isEmpty ||
            !documentIds.add(raw['id'] as String)) {
          throw StateError('Backup contains duplicate document metadata IDs or an invalid document ID.');
        }
      }

      final tableNames = ['folders', 'documents', 'categories', 'tags',
        'document_tags', 'reminders', 'history', 'settings', 'document_text_index'];
      final rowsByTable = <String, List<Map<String, Object?>>>{};
      for (final table in tableNames) {
        final tableFile = decoded.findFile('$table.json');
        if (tableFile == null && table == 'document_text_index' &&
            declaredTables[table] == null) {
          rowsByTable[table] = <Map<String, Object?>>[];
          continue;
        }
        if (tableFile == null) {
          throw StateError('Backup is incomplete: missing $table metadata.');
        }
        final tableRows = jsonDecode(utf8.decode(tableFile.content as List<int>));
        if (tableRows is! List) throw StateError('Backup contains invalid $table metadata.');
        final declaredCount = declaredTables[table];
        if (declaredCount is! int || declaredCount != tableRows.length) {
          throw StateError('Backup metadata count mismatch for $table.');
        }
        rowsByTable[table] = tableRows
            .map((value) => Map<String, Object?>.from(value as Map))
            .toList();
      }
      BackupFolderGraphValidator.validate(rowsByTable['folders']!);
      try {
        PortableSnapshotManifest.validateFolderRows(rowsByTable['folders']!);
        PortableSnapshotManifest.validateRelations(rowsByTable);
      } on FormatException catch (error) {
        final message = error.message.toString();
        if (message.contains('document tag')) {
          throw StateError('Backup document-tag reference points to a missing record.');
        }
        throw StateError(message);
      }
      PortableSnapshotRowsValidator.validate(rowsByTable);

      final rawFiles = manifest['files'];
      if (rawFiles is! List) throw StateError('Backup file manifest is invalid.');
      staging = await Directory.systemTemp.createTemp('docsgrid_restore_');
      final stagedPdfPaths = <String, String>{};
      final seenDocuments = <String>{};
      final seenEntries = <String>{};
      for (final raw in rawFiles) {
        if (raw is! Map ||
            raw['documentId'] is! String ||
            raw['entry'] is! String ||
            raw['sha256'] is! String ||
            !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(raw['sha256'] as String) ||
            (raw['originalName'] != null && raw['originalName'] is! String)) {
          throw StateError('Backup contains an invalid PDF manifest record.');
        }
        final documentId = raw['documentId'] as String;
        final entryName = raw['entry'] as String;
        if (!documentIds.contains(documentId)) {
          throw StateError('Backup contains orphaned PDF entries that reference missing document metadata.');
        }
        if (!seenDocuments.add(documentId) || !seenEntries.add(entryName)) {
          throw StateError('Backup contains duplicate PDF entries.');
        }
        if (!entryName.startsWith('pdfs/') ||
            entryName.contains('\\') ||
            entryName.split('/').any((part) => part.isEmpty || part == '.' || part == '..')) {
          throw StateError('Backup contains an unsafe PDF entry path.');
        }
        final entry = decoded.findFile(entryName);
        if (entry == null || !entry.isFile || entry.isSymbolicLink) {
          throw StateError('Backup is incomplete or contains a non-file PDF entry.');
        }
        final stagedFile = File(p.join(staging.path, '${_uuid.v4()}.pdf'));
        final output = OutputFileStream(stagedFile.path);
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
        final header = await stagedFile.openRead(0, 1024).fold<List<int>>(
          <int>[], (bytes, chunk) => bytes..addAll(chunk),
        );
        if (!String.fromCharCodes(header).contains('%PDF-')) {
          throw StateError('Backup contains a file that is not a valid PDF.');
        }
        final digest = (await sha256.bind(stagedFile.openRead()).first).toString();
        if (digest != (raw['sha256'] as String).toLowerCase()) {
          throw StateError('Backup integrity check failed.');
        }
        stagedPdfPaths[documentId] = stagedFile.path;
      }
      if (seenDocuments.length != documentIds.length ||
          !seenDocuments.containsAll(documentIds)) {
        throw StateError('Backup contains orphaned PDF entries: every document must have exactly one PDF entry.');
      }
      final expectedEntries = <String>{
        'manifest.json',
        for (final table in tableNames)
          if (archiveNames.contains('$table.json')) '$table.json',
        for (final raw in rawFiles) (raw as Map)['entry'] as String,
      };
      if (archiveNames.length != expectedEntries.length ||
          !archiveNames.containsAll(expectedEntries)) {
        throw StateError('Backup contains unexpected or unreferenced ZIP entries.');
      }
      input.closeSync();
      return _ValidatedBackup(
        manifest: manifest,
        rowsByTable: rowsByTable,
        stagedPdfPaths: stagedPdfPaths,
        stagingDirectory: staging,
      );
    } catch (_) {
      try { input.closeSync(); } catch (_) {}
      if (staging != null) {
        try { if (await staging.exists()) await staging.delete(recursive: true); } catch (_) {}
      }
      rethrow;
    }
  }
}

class _ValidatedBackup {
  const _ValidatedBackup({
    required this.manifest,
    required this.rowsByTable,
    required this.stagedPdfPaths,
    required this.stagingDirectory,
  });

  final Map<String, dynamic> manifest;
  final Map<String, List<Map<String, Object?>>> rowsByTable;
  final Map<String, String> stagedPdfPaths;
  final Directory stagingDirectory;

  Future<void> dispose() async {
    try {
      if (await stagingDirectory.exists()) {
        await stagingDirectory.delete(recursive: true);
      }
    } catch (_) {}
  }
}

