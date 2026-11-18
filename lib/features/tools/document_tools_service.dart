import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart' show InputFileStream, OutputFileStream, ZipFileEncoder;
import 'package:crypto/crypto.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';
import '../../core/storage/storage_location_service.dart';
import '../../core/storage/storage_migration_gate.dart';
import '../documents/data/document_repository.dart';
import '../folders/data/folder_repository.dart';
import '../reminders/data/reminder_notifications.dart';
import 'backup_archive_limits.dart';
import 'backup_schema_compatibility.dart';
import 'backup_folder_graph_validator.dart';
import 'portable_snapshot_manifest.dart';
import 'portable_snapshot_retention.dart';
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

/// Restore behavior for portable DocsGrid archives.
enum BackupRestoreMode { merge, fullReplacement, selective }

enum BackupRestoreSection {
  documents,
  folders,
  categories,
  tags,
  reminders,
  history,
  settings,
  smartCollections,
  ocrIndexes,
}

/// Local-only utilities for indexing, scanning, sharing and portable backups.
/// This service never uploads document contents to a remote server.
class DocumentToolsService {
  DocumentToolsService({AppDatabase? database,
    @visibleForTesting Future<Map<String, String>> Function()? snapshotLocations,
  }) : _database = database ?? AppDatabase.instance,
       _snapshotLocations = snapshotLocations;

  final Future<Map<String, String>> Function()? _snapshotLocations;

  final AppDatabase _database;
  static const _uuid = Uuid();
  // Snapshot publication/cleanup and restore must not overlap, including calls
  // made through different service instances in the foreground isolate.
  static Future<void> _recoveryTail = Future<void>.value();
  static Future<T> _withRecoveryLock<T>(Future<T> Function() action) async {
    final previous = _recoveryTail;
    final done = Completer<void>();
    _recoveryTail = done.future;
    await previous;
    try { return await action(); } finally { done.complete(); }
  }


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

  /// Whitelisted legacy library locations. Recovery must never broaden this
  /// list to the Phone tab's general shared-storage roots.
  @visibleForTesting
  static List<({String path, bool preserveFolders})>
      legacyManagedRecoveryPaths(String legacyRoot) => [
        (
          path: p.join(legacyRoot, 'My Files', 'Unfiled'),
          preserveFolders: false,
        ),
        (
          path: p.join(legacyRoot, 'My Files', 'Folders'),
          preserveFolders: true,
        ),
        (path: p.join(legacyRoot, 'Documents'), preserveFolders: false),
        (path: p.join(legacyRoot, 'Folders'), preserveFolders: true),
        (path: p.join(legacyRoot, 'Unfiled'), preserveFolders: false),
        // The earliest Android releases stored library PDFs in a dedicated
        // top-level PDFs directory. The install detector still recognizes it;
        // recovery must include the same explicitly managed legacy location.
        (path: p.join(legacyRoot, 'PDFs'), preserveFolders: false),
      ];

  /// Converts the UI breadcrumb separator ("Parent / Child") into the
  /// portable relative-path form ("Parent/Child") used by storage traversal.
  /// Folder names themselves cannot contain slashes, so this is unambiguous.
  @visibleForTesting
  static String normalizeRecoveryFolderPath(String value) => value
      .split('/')
      .map((segment) => segment.trim())
      .where((segment) => segment.isNotEmpty)
      .join('/');

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

  Future<int> indexPdfText(
    String documentId,
    String path, {
    bool Function()? shouldCancel,
  }) async {
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
        return await _indexPdfTextInternal(documentId, path, shouldCancel: shouldCancel);
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

  Future<int> _indexPdfTextInternal(
    String documentId,
    String path, {
    bool Function()? shouldCancel,
  }) async {
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
    TextRecognizer? recognizer;
    TextRecognizer? devanagariRecognizer;
    final pages = StringBuffer();
    try {
      if (shouldCancel?.call() ?? false) throw const OcrIndexCancelled();
      recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      if (Platform.isAndroid) {
        devanagariRecognizer = TextRecognizer(script: TextRecognitionScript.devanagiri);
      }
      for (var pageNumber = 1; pageNumber <= document.pagesCount; pageNumber++) {
        if (shouldCancel?.call() ?? false) throw const OcrIndexCancelled();
        final page = await document.getPage(pageNumber);
        try {
          final rendered = await page.render(
            width: (page.width * 1.5).clamp(900, 1800).toDouble(),
            height: (page.height * 1.5).clamp(900, 2400).toDouble(),
            format: pdfx.PdfPageImageFormat.png,
          );
          if (shouldCancel?.call() ?? false) throw const OcrIndexCancelled();
          if (rendered == null) continue;
          final temp = await getTemporaryDirectory();
          final image = File(p.join(temp.path, 'ocr_${_uuid.v4()}.png'));
          try {
            await image.writeAsBytes(rendered.bytes, flush: true);
            final input = InputImage.fromFilePath(image.path);
            final latinResult = await recognizer.processImage(input);
            if (shouldCancel?.call() ?? false) throw const OcrIndexCancelled();
            final extracted = <String>[latinResult.text];
            if (devanagariRecognizer != null) {
              final devanagariResult = await devanagariRecognizer.processImage(input);
              if (shouldCancel?.call() ?? false) throw const OcrIndexCancelled();
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
      // A failure while closing one native resource must never prevent the
      // remaining recognizer/PDF handles from being released.
      try {
        await recognizer?.close();
      } finally {
        try {
          await devanagariRecognizer?.close();
        } finally {
          await document.close();
        }
      }
    }
    if (shouldCancel?.call() ?? false) throw const OcrIndexCancelled();
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


  Future<int> indexPdfTextFromUri(
    String documentId,
    String storageUri, {
    bool Function()? shouldCancel,
  }) async {
    if (storageUri.startsWith('content://') || storageUri.startsWith('file://')) {
      final temp = await getTemporaryDirectory();
      final file = File(p.join(temp.path, 'ocr_source_${_uuid.v4()}.pdf'));
      try {
        await StorageLocationService.instance.copyPdfToPath(
          sourceUri: storageUri,
          destinationPath: file.path,
        );
        if (shouldCancel?.call() ?? false) throw const OcrIndexCancelled();
        return await indexPdfText(documentId, file.path, shouldCancel: shouldCancel);
      } finally {
        if (await file.exists()) await file.delete();
      }
    }
    final path = storageUri.startsWith('file://')
        ? Uri.parse(storageUri).toFilePath()
        : storageUri;
    return indexPdfText(documentId, path, shouldCancel: shouldCancel);
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

  Future<File> createBackup({
    void Function(int, int)? onProgress,
    bool includePdfs = true,
    bool backgroundSafe = false,
  }) async {
    await StorageMigrationGate.waitUntilReady();
    final storage = StorageLocationService.instance;
    final portableLocations = Platform.isAndroid
        ? (backgroundSafe
            ? await storage.cachedPortableDataLocations()
            : await storage.portableDataLocationsIfAvailable())
        : const <String, String>{};
    final destinationUri = includePdfs
        ? (portableLocations['fullBackupsUri'] ?? portableLocations['backupsUri'])
        : (portableLocations['databaseBackupsUri'] ?? portableLocations['backupsUri']);
    if (Platform.isAndroid && destinationUri == null) {
      throw StateError(
        'Set up DocsGrid storage before creating a backup.',
      );
    }
    if (backgroundSafe &&
        (destinationUri == null || !destinationUri.startsWith('file://'))) {
      throw StateError(
        'Background backup requires the initialized DocsGrid backup folder.',
      );
    }
    final db = await _database.database;
    final databaseSchemaVersion =
        Sqflite.firstIntValue(await db.rawQuery('PRAGMA user_version')) ?? 3;
    final tables = ['folders', 'documents', 'categories', 'tags',
      'document_tags', 'reminders', 'history', 'settings', 'document_text_index',
      'smart_collections'];
    final manifest = <String, Object?>{
      'format': 'DocsGridBackup',
      'version': 1,
      'backupType': includePdfs ? 'full' : 'database',
      'backupId': _uuid.v4(),
      'app': 'DocsGrid',
      'databaseSchemaVersion': databaseSchemaVersion,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'tables': <String, int>{},
      'metadataFiles': <Map<String, Object?>>[],
      'files': <Map<String, Object?>>[],
    };

    // SAF destinations are staged in cache, then copied into the selected tree.
    // iOS keeps its archive inside the app container; Android never creates
    // a second app-private DocsGrid backup library.
    final temporaryBase = await getTemporaryDirectory();
    final appDocuments = await getApplicationDocumentsDirectory();
    final portableBackupsUri = includePdfs
        ? (portableLocations['fullBackupsUri'] ?? portableLocations['backupsUri'])
        : (portableLocations['databaseBackupsUri'] ?? portableLocations['backupsUri']);
    final fallbackBackupPath = Platform.isAndroid
        ? p.join(temporaryBase.path, 'docsgrid_backup_staging', includePdfs ? 'Full' : 'Database')
        : p.join(appDocuments.path, 'DocsGrid', 'Backups', includePdfs ? 'Full' : 'Database');
    final backups = Directory(
      portableBackupsUri != null && portableBackupsUri.startsWith('file://')
          ? Uri.parse(portableBackupsUri).toFilePath()
          : fallbackBackupPath,
    );
    await backups.create(recursive: true);
    final temporaryUri = portableLocations['tempUri'];
    final temp = temporaryUri != null && temporaryUri.startsWith('file://')
        ? Directory(Uri.parse(temporaryUri).toFilePath())
        : await getTemporaryDirectory();
    await temp.create(recursive: true);
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
        'smart_collections': 'name COLLATE NOCASE, id',
      };
      // Hold a read transaction across metadata and PDF enumeration so
      // the archive represents one consistent database state.
      await db.transaction((txn) async {
        for (final table in tables) {
          final metadataFile = File(p.join(staging.path, '$table.json'));
          final outputFile = await metadataFile.open(mode: FileMode.write);
          var offset = 0;
          var rowCount = 0;
          try {
            await outputFile.writeString('[');
            while (true) {
              final rows = await txn.query(
                table,
                limit: 500,
                offset: offset,
                orderBy: orderBy[table],
              );
              if (rows.isEmpty) break;
              for (final row in rows) {
                final portableRow = Map<String, Object?>.from(row);
                if (table == 'documents') {
                  // Never export phone-specific absolute paths as backup
                  // references. Full archives map PDFs through manifest entries;
                  // database-only archives explicitly mark them as missing.
                  portableRow['storage_uri'] = includePdfs
                      ? 'backup-pdf://${row['id']}'
                      : 'missing://${row['id']}';
                  portableRow['relative_path'] = null;
                }
                if (rowCount > 0) await outputFile.writeString(',');
                await outputFile.writeString(jsonEncode(portableRow), encoding: utf8);
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
          final metadataDigest = (await sha256.bind(metadataFile.openRead()).first).toString();
          (manifest['metadataFiles'] as List).add({
            'entry': '$table.json',
            'sizeBytes': await metadataFile.length(),
            'sha256': metadataDigest,
          });
          await addStoredFile(metadataFile, '$table.json');
        }
  
        if (includePdfs) {
          final totalDocs = Sqflite.firstIntValue(
            await txn.rawQuery('SELECT COUNT(*) FROM documents'),
          ) ?? 0;
          var completed = 0;
          var documentOffset = 0;
          while (true) {
            final docs = await txn.query(
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
              if (backgroundSafe) {
                throw StateError(
                  'Background full backup cannot read a SAF content URI in a headless worker. Open DocsGrid to create a verified foreground full backup.',
                );
              }
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
        }
  
      });
      final manifestFile = File(p.join(staging.path, 'manifest.json'));
      await manifestFile.writeAsString(jsonEncode(manifest), encoding: utf8, flush: true);
      await addStoredFile(manifestFile, 'manifest.json');
      await encoder.close();
      encoderOpened = false;
      await BackupArchiveLimits.validate(output);
      // SAF locations use opaque content:// URIs rather than filesystem paths.
      // Publish the validated archive only after ZIP and manifest checks pass.
      if (!backgroundSafe &&
          portableBackupsUri != null &&
          portableBackupsUri.startsWith('content://')) {
        await storage.copyFileToStorage(
          sourcePath: output.path,
          parentUri: portableBackupsUri,
          name: p.basename(output.path),
          mimeType: 'application/zip',
        );
      }
      await _pruneBackupArchives(
        backups,
        keep: includePdfs ? 4 : 14,
        newestPath: output.path,
      );
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

  /// Retains four verified weekly full archives and fourteen database-only
  /// daily archives. Only DocsGrid-owned ZIPs are considered for cleanup.
  Future<void> _pruneBackupArchives(
    Directory directory, {
    required int keep,
    required String newestPath,
  }) async {
    try {
      if (!await directory.exists()) return;
      final files = await directory
          .list(followLinks: false)
          .where((entry) =>
              entry is File &&
              p.basename(entry.path).startsWith('DocsGrid_') &&
              p.extension(entry.path).toLowerCase() == '.zip')
          .cast<File>()
          .toList();
      files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      var retained = 0;
      for (final file in files) {
        if (file.path == newestPath || retained < keep) {
          retained++;
          continue;
        }
        try {
          // Never prune an archive until the new archive has passed validation.
          await file.delete();
        } catch (_) {
          // Retention is best-effort; failed cleanup never invalidates a backup.
        }
      }
    } catch (_) {
      // A listing/permission error must not invalidate the newly verified archive.
    }
  }

  /// Lists portable ZIP archives without trusting their filenames as proof
  /// of validity. The restore decoder performs the full manifest/checksum scan.
  Future<List<File>> listPortableBackupArchives() async {
    final storage = StorageLocationService.instance;
    final locations = Platform.isAndroid
        ? await storage.portableDataLocationsIfAvailable()
        : const <String, String>{};
    final directories = <String, Directory>{};

    void addDirectory(Directory directory) {
      directories[directory.path] = directory;
    }

    // Current installations write Full and Database archives to separate
    // directories. Inspect those exact directories and the parent for legacy
    // archives created before the split.
    for (final key in ['fullBackupsUri', 'databaseBackupsUri', 'backupsUri']) {
      final uri = locations[key];
      if (uri != null && uri.startsWith('file://')) {
        addDirectory(Directory(Uri.parse(uri).toFilePath()));
      }
    }

    final legacyUri = locations['legacyRootUri'];
    if (legacyUri != null && legacyUri.startsWith('file://')) {
      final legacyRoot = Uri.parse(legacyUri).toFilePath();
      for (final path in [
        p.join(legacyRoot, 'Backups'),
        p.join(legacyRoot, 'Backups', 'Full'),
        p.join(legacyRoot, 'Backups', 'Database'),
        p.join(legacyRoot, 'System', 'Backups'),
        p.join(legacyRoot, 'System', 'Backups', 'Full'),
        p.join(legacyRoot, 'System', 'Backups', 'Database'),
      ]) {
        addDirectory(Directory(path));
      }
    }

    // iOS and private fallback archives are also separated into Full/Database.
    if (!Platform.isAndroid || directories.isEmpty) {
      final backupRoot = p.join(
        (await getApplicationDocumentsDirectory()).path,
        'DocsGrid',
        'Backups',
      );
      addDirectory(Directory(backupRoot));
      addDirectory(Directory(p.join(backupRoot, 'Full')));
      addDirectory(Directory(p.join(backupRoot, 'Database')));
    }

    final files = <String, File>{};
    for (final directory in directories.values) {
      if (!await directory.exists()) continue;
      final entries = await directory
          .list(followLinks: false)
          .where((entity) =>
              entity is File &&
              p.basename(entity.path).startsWith('DocsGrid_') &&
              p.extension(entity.path).toLowerCase() == '.zip')
          .cast<File>()
          .toList();
      for (final file in entries) {
        files[file.path] = file;
      }
    }

    // SAF trees expose opaque content:// URIs. Stage only DocsGrid-owned ZIP
    // files via the native streaming copy bridge; never read archives into RAM.
    final stagedRoot = Directory(p.join(
      (await getTemporaryDirectory()).path,
      'docsgrid_portable_backup_staging',
    ));
    if (await stagedRoot.exists()) {
      await stagedRoot.delete(recursive: true);
    }
    await stagedRoot.create(recursive: true);

    Future<void> stageContentDirectory(
      String uri, {
      required String folderName,
    }) async {
      try {
        final entries = await storage.listDirectory(uri);
        final targetDirectory = Directory(p.join(stagedRoot.path, folderName));
        await targetDirectory.create(recursive: true);
        for (final entry in entries) {
          if (entry['isDirectory'] == true) continue;
          final name = entry['name'] as String? ?? '';
          final sourceUri = entry['uri'] as String? ?? '';
          if (!name.startsWith('DocsGrid_') ||
              !name.toLowerCase().endsWith('.zip') ||
              sourceUri.isEmpty) {
            continue;
          }
          final staged = File(p.join(targetDirectory.path, '${_uuid.v4()}_$name'));
          try {
            await storage.copyStorageFileToPath(
              sourceUri: sourceUri,
              destinationPath: staged.path,
            );
            files[staged.path] = staged;
          } catch (_) {
            // Skip only this unreadable item; other backups remain eligible.
          }
        }
      } catch (_) {
        // One inaccessible SAF/cloud folder must not hide other backup sources.
      }
    }

    final contentUris = <String, String>{};
    for (final key in ['fullBackupsUri', 'databaseBackupsUri', 'backupsUri']) {
      final uri = locations[key];
      if (uri != null && uri.startsWith('content://')) {
        contentUris[uri] = key;
      }
    }
    for (final entry in contentUris.entries) {
      final uri = entry.key;
      final key = entry.value;
      if (key == 'backupsUri') {
        await stageContentDirectory(uri, folderName: 'Legacy');
        // The parent contains the known Full and Database children. Do not
        // recurse into arbitrary provider folders.
        try {
          final children = await storage.listDirectory(uri);
          for (final child in children) {
            if (child['isDirectory'] != true) continue;
            final name = child['name'] as String? ?? '';
            if (name != 'Full' && name != 'Database') continue;
            final childUri = child['uri'] as String? ?? '';
            if (childUri.startsWith('content://')) {
              await stageContentDirectory(childUri, folderName: name);
            }
          }
        } catch (_) {}
      } else {
        await stageContentDirectory(
          uri,
          folderName: key == 'fullBackupsUri' ? 'Full' : 'Database',
        );
      }
    }

    return files.values.toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  }

  Future<Map<String, int>> recoverLoosePortablePdfs({
    void Function(int completed, int total)? onProgress,
  }) async {
    await StorageMigrationGate.waitUntilReady();
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'Automatic shared-media recovery is currently Android-only.',
      );
    }

    final storage = StorageLocationService.instance;
    final locations = await storage.portableDataLocationsIfAvailable();
    final documentsRoot = locations['documentsUri'];
    final foldersRoot = locations['libraryUri'];
    if (documentsRoot == null && foldersRoot == null) {
      throw StateError(
        'No accessible DocsGrid recovery folders were found. '
        'Restore the existing DocsGrid storage location first.',
      );
    }

    final roots = <({String uri, bool preserveFolders})>[];
    if (documentsRoot != null) {
      roots.add((uri: documentsRoot, preserveFolders: false));
    }
    if (foldersRoot != null) {
      roots.add((uri: foldersRoot, preserveFolders: true));
    }

    // Older releases stored the same managed library below Android/media/DocsGrid.
    // Support both the original direct layout and the later "My Files" layout,
    // but never recurse through the legacy root itself (which also contains
    // backups, snapshots, caches and other non-library content).
    final legacyUri = locations['legacyRootUri'];
    if (legacyUri != null && legacyUri.startsWith('file://')) {
      final legacyRoot = Directory(Uri.parse(legacyUri).toFilePath());
      final legacyLayouts =
          DocumentToolsService.legacyManagedRecoveryPaths(legacyRoot.path);
      for (final legacy in legacyLayouts) {
        final directory = Directory(legacy.path);
        if (await directory.exists()) {
          roots.add((
            uri: Uri.directory(directory.path).toString(),
            preserveFolders: legacy.preserveFolders,
          ));
        }
      }
    }

    final candidates = <Map<String, Object?>>[];
    final seenUris = <String>{};
    var failed = 0;

    Future<void> addPortableRoot(
      String uri, {
      required bool preserveFolders,
    }) async {
      try {
        final files = await storage.listPdfFilesRecursively(uri);
        for (final item in files) {
          final name = item['name'] as String? ?? '';
          final fileUri = item['uri'] as String? ?? '';
          if (!name.toLowerCase().endsWith('.pdf') ||
              fileUri.isEmpty ||
              !seenUris.add(fileUri)) {
            continue;
          }
          candidates.add({
            'name': name,
            'uri': fileUri,
            // "Unfiled" PDFs are library root documents. Only PDFs already
            // stored under the managed Folders tree retain a folder hierarchy.
            'folderPath': preserveFolders
                ? (item['folderPath'] as String? ?? '')
                : '',
          });
        }
      } catch (_) {
        // Preserve partial recovery from other valid DocsGrid roots.
        failed++;
      }
    }

    for (final root in roots) {
      await addPortableRoot(
        root.uri,
        preserveFolders: root.preserveFolders,
      );
    }

    final folderRepository = FolderRepository();
    final documentRepository = DocumentRepository();

    // Reuse paths already restored from a metadata snapshot. This makes
    // repeated recovery idempotent and prevents duplicate nested folders.
    final folderIdsByPath = <String, String>{};
    for (final existing in await folderRepository.allFoldersWithPaths()) {
      folderIdsByPath[normalizeRecoveryFolderPath(existing.path)] =
          existing.folder.id;
    }
    var createdFolders = 0;

    Future<String?> ensureFolderPath(String path) async {
      if (path.isEmpty) return null;
      String? parentId;
      var currentPath = '';
      for (final rawSegment in normalizeRecoveryFolderPath(path)
          .split('/')
          .where((value) => value.isNotEmpty)) {
        final segment = FolderRepository.validateFolderName(rawSegment);
        currentPath = currentPath.isEmpty ? segment : '$currentPath/$segment';
        final cached = folderIdsByPath[currentPath];
        if (cached != null) {
          parentId = cached;
          continue;
        }
        try {
          final created = await folderRepository.create(
            name: segment,
            parentId: parentId,
            reuseExistingPhysical: true,
          );
          folderIdsByPath[currentPath] = created.id;
          parentId = created.id;
          createdFolders++;
        } on StateError {
          // Another recovery/import may have created this Grid folder.
          // Reuse only a verified active folder; do not mistake failures
          // to access physical storage for successful folder creation.
          final matches = await folderRepository.allFoldersWithPaths();
          final current = matches.where((item) =>
              normalizeRecoveryFolderPath(item.path).toLowerCase() ==
              currentPath.toLowerCase()).toList();
          if (current.length != 1) rethrow;
          parentId = current.single.folder.id;
          folderIdsByPath[currentPath] = parentId;
        }
      }
      return parentId;
    }

    var added = 0;
    var duplicates = 0;
    var processed = 0;
    final total = candidates.length;
    onProgress?.call(0, total);
    for (final item in candidates) {
      try {
        final folderId = await ensureFolderPath(item['folderPath'] as String);
        final imported = await documentRepository.importExistingSharedPdf(
          storageUri: item['uri'] as String,
          displayName: item['name'] as String,
          targetFolderId: folderId,
        );
        if (imported) {
          added++;
        } else {
          duplicates++;
        }
      } catch (_) {
        failed++;
      } finally {
        processed++;
        onProgress?.call(processed, total);
      }
    }

    return {
      'added': added,
      'duplicates': duplicates,
      'failed': failed,
      'folders': createdFolders,
    };
  }

  /// Reads only the declared backup type after ZIP bounds and path checks.
  /// v1 archives without backupType are treated as Full for compatibility with
  /// the original format, which had no database-only mode.
  Future<String> _readPortableBackupType(File zipFile) async {
    await BackupArchiveLimits.validate(zipFile);
    final input = InputFileStream(zipFile.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final entry = archive.findFile('manifest.json');
      if (entry == null || !entry.isFile || entry.isSymbolicLink) {
        throw StateError('This is not a DocsGrid backup.');
      }
      final value = jsonDecode(utf8.decode(entry.content as List<int>));
      if (value is! Map<String, dynamic> ||
          value['format'] != 'DocsGridBackup' ||
          value['version'] != 1) {
        throw StateError('Unsupported backup format or version.');
      }
      final type = value['backupType'];
      if (type == null || type == 'full') return 'full';
      if (type == 'database') return 'database';
      throw StateError('Backup type is not supported.');
    } finally {
      try { input.closeSync(); } catch (_) {}
    }
  }

  /// Full archives always take priority over database-only archives, regardless
  /// of modification time. A broken archive is skipped and the next candidate
  /// is tried; Database archives are used only after every Full archive fails.
  Future<int?> restoreNewestPortableBackup({
    Future<bool> Function(int pdfCount)? confirm,
    Future<bool> Function(Map<String, int> preview)? confirmPlan,
  }) async {
    await StorageMigrationGate.waitUntilReady();
    final candidates = await listPortableBackupArchives();
    if (candidates.isEmpty) {
      throw StateError('No portable DocsGrid backup ZIP was found.');
    }

    final stagedRoot = Directory(p.join(
      (await getTemporaryDirectory()).path,
      'docsgrid_portable_backup_staging',
    ));
    final classified = <({File file, int priority, DateTime modified})>[];
    for (final candidate in candidates) {
      try {
        // New archives are stored in explicit Full/Database folders, so their
        // type is known without decompressing a large archive just to inspect
        // its manifest. Only legacy flat archives need manifest classification.
        final parentType = p.basename(candidate.parent.path).toLowerCase();
        final type = parentType == 'full'
            ? 'full'
            : parentType == 'database'
                ? 'database'
                : await _readPortableBackupType(candidate);
        classified.add((
          file: candidate,
          priority: type == 'full' ? 0 : 1,
          modified: await candidate.lastModified(),
        ));
      } catch (_) {
        classified.add((
          file: candidate,
          priority: 2,
          modified: await candidate.lastModified(),
        ));
      }
    }
    classified.sort((a, b) {
      final byType = a.priority.compareTo(b.priority);
      return byType != 0 ? byType : b.modified.compareTo(a.modified);
    });

    Object? lastError;
    try {
      for (final item in classified) {
        try {
          return await restoreBackup(item.file, confirm: confirm, confirmPlan: confirmPlan);
        } catch (error) {
          lastError = error;
        }
      }
      throw StateError(
        'No valid portable backup could be restored. '
        'Full archives were checked before Database archives. Last error: $lastError',
      );
    } finally {
      if (await stagedRoot.exists()) {
        try { await stagedRoot.delete(recursive: true); } catch (_) {}
      }
    }
  }

  /// Creates a verified Full archive and portable pointer record before
  /// any restore mode mutates the live database or managed PDF tree.
  Future<void> _createRestoreSafetyCheckpoint({
    required BackupRestoreMode mode,
    required String sourceBackupId,
  }) async {
    final checkpointArchive = await createBackup(includePdfs: true);
    final digest = await sha256.bind(checkpointArchive.openRead()).first;
    final record = <String, Object?>{
      'format': 'DocsGridRestoreCheckpoint',
      'version': 1,
      'status': 'verified',
      'restoreMode': mode.name,
      'sourceBackupId': sourceBackupId,
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
      'archiveName': p.basename(checkpointArchive.path),
      'archiveBytes': await checkpointArchive.length(),
      'archiveSha256': digest.toString(),
      'archiveBackupType': 'full',
    };

    final locations = Platform.isAndroid
        ? await StorageLocationService.instance.portableDataLocationsIfAvailable()
        : const <String, String>{};
    final checkpointUri = locations['restoreCheckpointsUri'];
    if (checkpointUri != null) {
      await StorageLocationService.instance.writeTextFile(
        parentUri: checkpointUri,
        name: 'checkpoint_${DateTime.now().toUtc().millisecondsSinceEpoch}_${_uuid.v4()}.json',
        contents: jsonEncode(record),
      );
    } else {
      final support = await getApplicationSupportDirectory();
      final directory = Directory(p.join(
        support.path, 'docsgrid', 'recovery', 'checkpoints',
      ));
      await directory.create(recursive: true);
      final file = File(p.join(
        directory.path,
        'checkpoint_${DateTime.now().toUtc().millisecondsSinceEpoch}_${_uuid.v4()}.json',
      ));
      await file.writeAsString(jsonEncode(record), flush: true);
    }
  }

  /// Additively restores a verified archive. Existing document/folder IDs are
  /// never overwritten; any collision aborts the database transaction.
  Future<int?> restoreBackup(
    File zipFile, {
    Future<bool> Function(int pdfCount)? confirm,
    Future<bool> Function(Map<String, int> preview)? confirmPlan,
    BackupRestoreMode mode = BackupRestoreMode.merge,
    Set<BackupRestoreSection>? selection,
  }) => _withRecoveryLock(() => _restoreBackupLocked(
    zipFile, confirm: confirm, mode: mode, selection: selection,
    confirmPlan: confirmPlan,
  ));

Future<int?> _restoreBackupLocked(
    File zipFile, {
    Future<bool> Function(int pdfCount)? confirm,
    Future<bool> Function(Map<String, int> preview)? confirmPlan,
    BackupRestoreMode mode = BackupRestoreMode.merge,
    Set<BackupRestoreSection>? selection,
  }) async {

    await StorageMigrationGate.waitUntilReady();
    final backup = await _decodeValidatedBackup(zipFile);
    try {
      final pdfCount = (backup.manifest['files'] as List<dynamic>).length;
      bool hasRows(String table) =>
          (backup.rowsByTable[table] ?? const <Map<String, Object?>>[]).isNotEmpty;
      final hasCustomCategories =
          (backup.rowsByTable['categories'] ?? const <Map<String, Object?>>[])
              .any((row) => (row['is_builtin'] as num?)?.toInt() != 1);
      final hasRecoverableData = pdfCount > 0 ||
          hasRows('documents') ||
          hasRows('folders') ||
          hasCustomCategories ||
          hasRows('tags') ||
          hasRows('document_tags') ||
          hasRows('reminders') ||
          hasRows('history') ||
          hasRows('settings') ||
          hasRows('smart_collections') ||
          hasRows('document_text_index');
      if (!hasRecoverableData) {
        throw StateError(
          'This ZIP is readable, but contains no user PDFs, folders or records. '
          'Choose Recover existing PDFs to rebuild the library from files still '
          'present on this phone.',
        );
      }
      if (confirm != null && !await confirm(pdfCount)) return null;
      if (mode == BackupRestoreMode.selective) {
        if (selection == null || selection.isEmpty) {
          throw ArgumentError('Select at least one data group to restore.');
        }
        // OCR indexes require their document rows and PDF payloads.
        final includeDocuments = selection.contains(BackupRestoreSection.documents) ||
            selection.contains(BackupRestoreSection.ocrIndexes);
        final includeFolders = includeDocuments || selection.contains(BackupRestoreSection.folders);
        final includeCategories = includeDocuments || selection.contains(BackupRestoreSection.categories);
        final includeTags = includeDocuments || selection.contains(BackupRestoreSection.tags);
        final rows = <String, List<Map<String, Object?>>>{
          for (final table in backup.rowsByTable.keys) table: <Map<String, Object?>>[],
        };
        if (includeFolders) rows['folders'] = backup.rowsByTable['folders']!;
        if (includeDocuments) rows['documents'] = backup.rowsByTable['documents']!;
        if (includeCategories) rows['categories'] = backup.rowsByTable['categories']!;
        if (includeTags) rows['tags'] = backup.rowsByTable['tags']!;
        if (includeDocuments) rows['document_tags'] = backup.rowsByTable['document_tags']!;
        if (selection.contains(BackupRestoreSection.reminders) ||
            selection.contains(BackupRestoreSection.history)) {
          final liveDb = await _database.database;
          final liveDocumentRows = await liveDb.query('documents', columns: ['id']);
          final liveDocumentIds = liveDocumentRows
              .map((row) => row['id'] as String)
              .toSet();
          bool safeOptionalReference(Map<String, Object?> row) {
            final documentId = row['document_id'];
            return documentId == null ||
                (documentId is String && liveDocumentIds.contains(documentId)) ||
                (includeDocuments && documentId is String &&
                    backup.rowsByTable['documents']!.any((doc) => doc['id'] == documentId));
          }
          if (selection.contains(BackupRestoreSection.reminders)) {
            rows['reminders'] = backup.rowsByTable['reminders']!
                .where(safeOptionalReference).toList();
          }
          if (selection.contains(BackupRestoreSection.history)) {
            rows['history'] = backup.rowsByTable['history']!
                .where(safeOptionalReference).toList();
          }
        }
        if (selection.contains(BackupRestoreSection.settings)) {
          rows['settings'] = backup.rowsByTable['settings']!;
        }
        if (selection.contains(BackupRestoreSection.smartCollections)) {
          rows['smart_collections'] = backup.rowsByTable['smart_collections']!;
        }
        if (selection.contains(BackupRestoreSection.ocrIndexes)) {
          if (includeDocuments) {
            rows['document_text_index'] = backup.rowsByTable['document_text_index']!;
          } else {
            final liveDb = await _database.database;
            final liveRows = await liveDb.query('documents', columns: ['id']);
            final liveIds = liveRows.map((row) => row['id'] as String).toSet();
            rows['document_text_index'] = backup.rowsByTable['document_text_index']!
                .where((row) => liveIds.contains(row['document_id']))
                .toList();
          }
        }
        final selectiveBackup = _ValidatedBackup(
          manifest: backup.manifest,
          rowsByTable: rows,
          stagedPdfPaths: includeDocuments ? backup.stagedPdfPaths : const <String, String>{},
          stagingDirectory: backup.stagingDirectory,
        );
        return await _restoreValidatedBackup(
          selectiveBackup,
          restoreMode: BackupRestoreMode.selective.name,
          confirmPlan: confirmPlan,
        );
      }
      return await _restoreValidatedBackup(
        backup,
        replaceExisting: mode == BackupRestoreMode.fullReplacement,
        restoreMode: mode.name,
        confirmPlan: confirmPlan,
      );
    } finally {
      await backup.dispose();
    }
  }

  Future<int?> _restoreValidatedBackup(
    _ValidatedBackup backup, {
    bool replaceExisting = false,
    String restoreMode = 'merge',
    Future<bool> Function(Map<String, int> preview)? confirmPlan,
  }) async {
    final manifest = backup.manifest;
    final rowsByTable = backup.rowsByTable;
    final folderRows = rowsByTable['folders']!;
    final documentsById = <String, Map<String, Object?>>{
      for (final row in rowsByTable['documents']!) row['id'] as String: row,
    };
    final db = await _database.database;
    final inventoryRevision = await _database.portableSnapshotRevision();
    // Keep every persisted ID for collision detection, but only active folders
    // participate in path matching. A soft-deleted row still owns its primary key.
    final existingFolderRows = await db.query('folders');
    BackupFolderGraphValidator.validate(folderRows);
    for (final row in folderRows) {
      FolderRepository.validateFolderName(row['name'] as String);
    }
    final existingFolders = existingFolderRows
        .where((row) => row['deleted_at'] == null)
        .toList(growable: false);
    final existingFolderIds =
        existingFolderRows.map((row) => row['id'] as String).toSet();
    final existingFolderIdsByPath = <String, String>{};
    final livePaths = <String, String>{};
    for (final row in BackupFolderGraphValidator.parentFirst(existingFolders)) {
      final id = row['id'] as String;
      final parent = row['parent_id'] as String?;
      final path = (parent == null ? row['name'] as String
          : '${livePaths[parent]}/${row['name']}').toLowerCase();
      if (existingFolderIdsByPath.containsKey(path)) {
        throw StateError('Folder conflict: multiple active folders at $path.');
      }
      livePaths[id] = path;
      existingFolderIdsByPath[path] = id;
    }
    final backupFolderPaths = <String, String>{};
    for (final row in BackupFolderGraphValidator.parentFirst(folderRows)) {
      final parent = row['parent_id'] as String?;
      backupFolderPaths[row['id'] as String] = parent == null
          ? row['name'] as String : '${backupFolderPaths[parent]}/${row['name']}';
    }
    String backupFolderPath(String id) => backupFolderPaths[id]!;
    final folderIdMap = <String, String>{};
    final matchedFolderIds = <String>{};
    final matchedRowsBySourceId = <String, Map<String, Object?>>{};
    final allLivePaths = <String, String>{};
    for (final row in BackupFolderGraphValidator.parentFirst(existingFolderRows)) {
      final parent = row['parent_id'] as String?;
      allLivePaths[row['id'] as String] = parent == null ? row['name'] as String
          : '${allLivePaths[parent]}/${row['name']}';
    }
    for (final row in BackupFolderGraphValidator.parentFirst(folderRows)) {
      final oldId = row['id'] as String;
      final deletedMatches = existingFolderRows.where((live) =>
          row['deleted_at'] != null && live['deleted_at'] != null &&
          live['id'] == oldId && live['created_at'] == row['created_at'] &&
          live['trash_operation_id'] == row['trash_operation_id'] &&
          allLivePaths[oldId]?.toLowerCase() == backupFolderPath(oldId).toLowerCase());
      final match = row['deleted_at'] == null
          ? existingFolderIdsByPath[backupFolderPath(oldId).toLowerCase()]
          : (deletedMatches.isEmpty ? null : deletedMatches.single['id'] as String);
      if (row['deleted_at'] != null &&
          existingFolderIdsByPath.containsKey(backupFolderPath(oldId).toLowerCase())) {
        throw StateError('Recycle Bin conflict with active folder: ${backupFolderPath(oldId)}');
      }
      if (match != null) {
        final candidate = existingFolderRows.firstWhere((live) => live['id'] == match);
        // Path + independent identity evidence; names or IDs alone are unsafe.
        if (match != oldId && candidate['created_at'] != row['created_at']) {
          throw StateError('Folder conflict: ${backupFolderPath(oldId)} has a different identity. No files were imported.');
        }
        folderIdMap[oldId] = replaceExisting ? oldId : match;
        matchedFolderIds.add(oldId);
        matchedRowsBySourceId[oldId] = candidate;
      } else {
        folderIdMap[oldId] = !replaceExisting && existingFolderIds.contains(oldId)
            ? _uuid.v5(Uuid.NAMESPACE_URL, 'DocsGrid/folder/${manifest['backupId']}/$oldId')
            : oldId;
      }
    }
    final existingDocuments = await db.query('documents');
    final existingDocumentsById = {for (final row in existingDocuments) row['id'] as String: row};
    // Independently managed documents may contain identical PDF bytes.
    final existingDocumentIds = existingDocuments.map((row) => row['id'] as String).toSet();
    final verifiedDocumentIds = <String>{};
    final ownedStoragePaths = <String>{
      for (final row in existingDocuments)
        if (row['storage_uri'] is String &&
            !(row['storage_uri'] as String).startsWith('missing://') &&
            !(row['storage_uri'] as String).startsWith('content://'))
          p.normalize((row['storage_uri'] as String).startsWith('file://')
              ? Uri.parse(row['storage_uri'] as String).toFilePath()
              : row['storage_uri'] as String),
    };
    for (final row in existingDocuments) {
      final digest = row['sha256'] as String?;
      final uri = row['storage_uri'] as String?;
      if (digest == null || uri == null || uri.startsWith('missing://')) continue;
      try {
        final actual = uri.startsWith('content://')
            ? await StorageLocationService.instance.sha256Pdf(uri)
            : (await sha256.bind(File(uri.startsWith('file://')
                ? Uri.parse(uri).toFilePath() : uri).openRead()).first).toString();
        if (actual == digest) {
          verifiedDocumentIds.add(row['id'] as String);
          // Keep this verified path owned by its original logical document.
        }
      } catch (_) { /* Missing bytes are never treated as restored. */ }
    }
    // The archive may contain independent logical documents with identical
    // PDF bytes. Preserve both identities and independent physical paths.
    final documentIdMap = <String, String>{};
    final duplicateDocumentIds = <String>{};
    final repairDocumentIds = <String>{};
    for (final row in rowsByTable['documents']!) {
      final oldId = row['id'] as String;
      final digest = row['sha256'] as String?;
      final oldFolder = row['folder_id'] as String?;
      final mappedFolder = oldFolder == null ? null : folderIdMap[oldFolder];
      final stableId = _uuid.v5(Uuid.NAMESPACE_URL,
          'DocsGrid/document/${manifest['backupId']}/$oldId');
      final matches = [existingDocumentsById[oldId], existingDocumentsById[stableId]]
          .whereType<Map<String, Object?>>().where((candidate) =>
          candidate['sha256'] == digest && candidate['folder_id'] == mappedFolder &&
          candidate['deleted_at'] == row['deleted_at']);
      final match = matches.isEmpty ? null : matches.first;
      if (!replaceExisting && match != null &&
          verifiedDocumentIds.contains(match['id'])) {
        documentIdMap[oldId] = match['id'] as String;
        duplicateDocumentIds.add(oldId);
      } else {
        if (!replaceExisting && match != null) {
          documentIdMap[oldId] = match['id'] as String;
          repairDocumentIds.add(oldId);
        } else {
          documentIdMap[oldId] = !replaceExisting && existingDocumentIds.contains(oldId)
              ? stableId : oldId;
          if (!replaceExisting && existingDocumentIds.contains(documentIdMap[oldId])) {
            throw StateError('Document identity conflict: ${row['name']}');
          }
        }
      }
    }
    // A ZIP is untrusted input. Validate parent links before creating any
    // directories, and never use imported IDs as filesystem path segments.
    BackupFolderGraphValidator.validate(folderRows);
    final externalDocumentIds = replaceExisting
        ? <String>{}
        : existingDocuments.map((row) => row['id'] as String).toSet();
    PortableSnapshotRowsValidator.validate(
      rowsByTable,
      allowedExternalDocumentIds: externalDocumentIds,
    );
    final portableLocations = Platform.isAndroid
        ? await StorageLocationService.instance.portableDataLocationsIfAvailable()
        : const <String, String>{};
    final portableUnfiledUri = portableLocations['documentsUri'];
    final portableFoldersUri = portableLocations['libraryUri'];
    if (Platform.isAndroid &&
        (portableUnfiledUri == null ||
            !portableUnfiledUri.startsWith('file://') ||
            portableFoldersUri == null ||
            !portableFoldersUri.startsWith('file://'))) {
      throw StateError(
        'Allow Full internal storage access before restoring this ZIP backup.',
      );
    }
    final fallbackRoot = p.join(
      (await getApplicationDocumentsDirectory()).path,
      'DocsGrid',
      'Library',
    );
    final unfiledRoot = Directory(
      portableUnfiledUri != null && portableUnfiledUri.startsWith('file://')
          ? Uri.parse(portableUnfiledUri).toFilePath()
          : fallbackRoot,
    );
    final foldersRoot = Directory(
      portableFoldersUri != null && portableFoldersUri.startsWith('file://')
          ? Uri.parse(portableFoldersUri).toFilePath()
          : p.join(fallbackRoot, 'Folders'),
    );
    final restoreRoot = unfiledRoot;
    final fileRows = rowsByTable['documents']!.isEmpty
        ? <Map<String, dynamic>>[]
        : (manifest['files'] as List<dynamic>).cast<Map<String, dynamic>>();
    final restoredPaths = <String, String>{};
    final folderPaths = <String, String>{};
    final createdFiles = <String>[];
    final pendingFiles = <String>[];
    final createdDirectories = <String>[];
    // Restoration of a legacy timestamped folder needs a separately approved
    // relocation plan. The original folders and PDF bytes are never deleted.
    final legacyFolderPaths = <String, String>{};
    final claimedPaths = <String, String>{};
    for (final row in BackupFolderGraphValidator.parentFirst(folderRows)) {
      final id = row['id'] as String;
      final parentId = row['parent_id'] as String?;
      final parentPath = parentId == null ? foldersRoot.path : folderPaths[parentId]!;
      var path = p.join(parentPath, row['name'] as String);
      if (matchedFolderIds.contains(id)) {
        final uri = matchedRowsBySourceId[id]!['storage_uri_or_relative_path'] as String?;
        if (uri != null && uri.isNotEmpty) {
          if (uri.startsWith('content://')) {
            throw StateError('Folder conflict: SAF destination requires explicit relinking before ZIP restore: ${row['name']}');
          }
          final storedPath = uri.startsWith('file://')
              ? Uri.parse(uri).toFilePath() : uri;
          if (!p.isAbsolute(storedPath) || !await Directory(storedPath).exists()) {
            throw StateError('Folder mapping is unavailable: ${row['name']}. Restore storage access before retrying.');
          }
          // Old ZIP restores permanently routed every new PDF into a
          // Restored_<timestamp>/<name>_<hash> tree. A readable directory alone
          // is not proof that it is the correct *current* storage mapping.
          // Reconcile only against the already verified backup/live logical
          // folder identity; unrecognized paths remain untouched.
          if (FolderRepository.isLegacyRestoreStorageUri(uri)) {
            final normalizedOld = p.normalize(p.absolute(storedPath));
            if (!p.isWithin(foldersRoot.path, normalizedOld)) {
              throw StateError('Legacy restore folder is outside the authorized library.');
            }
            final original = p.normalize(p.absolute(path));
            if (!p.isWithin(foldersRoot.path, original)) {
              throw StateError('Original restore destination is outside the authorized library.');
            }
            final owner = existingFolderRows.where((candidate) {
              if (candidate['id'] == matchedRowsBySourceId[id]?['id']) return false;
              final value = candidate['storage_uri_or_relative_path'] as String?;
              if (value == null || value.startsWith('content://')) return false;
              final candidatePath = value.startsWith('file://')
                  ? Uri.parse(value).toFilePath() : value;
              return p.normalize(p.absolute(candidatePath)) == original;
            });
            if (owner.isNotEmpty) {
              throw StateError('Original folder is already owned by a different database record: ${row['name']}');
            }
            legacyFolderPaths[id] = normalizedOld;
            // Keep the intended hierarchy, not the legacy timestamped path.
          } else {
            path = storedPath;
          }
        }
      }
      path = p.normalize(p.absolute(path));
      if (await FileSystemEntity.type(path, followLinks: false) == FileSystemEntityType.link) {
        throw StateError('Folder conflict: symbolic link at $path');
      }
      // Deleted records must never claim the active hierarchy or its files.
      if (existingFolderRows.any((candidate) =>
          candidate['deleted_at'] != null && candidate['id'] != matchedRowsBySourceId[id]?['id'] &&
          (candidate['storage_uri_or_relative_path'] == path ||
           candidate['storage_uri_or_relative_path'] == Uri.file(path).toString()))) {
        throw StateError('Recycle Bin folder conflict: ${row['name']}. Restore it separately before importing this ZIP.');
      }
      if (claimedPaths.containsKey(path)) throw StateError('Ambiguous destination: $path');
      claimedPaths[path] = id;
      if (await Directory(path).exists()) await Directory(path).list().drain<void>();
      folderPaths[id] = path;
    }
    String folderPath(String id) => folderPaths[id]!;
    // Reuse an already-present PDF only when it belongs to the expected
    // directory and is not owned by another live logical record. Sharing one
    // physical path between distinct records would break move/permanent-delete.
    final availableByFolderAndHash = <String, List<String>>{};
    for (final directory in <String>{unfiledRoot.path, ...folderPaths.values}) {
      if (!await Directory(directory).exists()) continue;
      await for (final entry in Directory(directory).list(followLinks: false)) {
        if (entry is! File || !entry.path.toLowerCase().endsWith('.pdf')) continue;
        final path = p.normalize(entry.path);
        if (!replaceExisting && ownedStoragePaths.contains(path)) continue;
        final digest = (await sha256.bind(entry.openRead()).first).toString();
        (availableByFolderAndHash['${p.normalize(directory)}|$digest'] ??= <String>[])
            .add(path);
      }
    }
    final assignedPhysicalPaths = <String>{};
    // Inventory each existing active PDF tied to a legacy folder. We must
    // preserve its bytes and independent logical ownership before moving the
    // folder mapping. Source PDFs will be left in place for rollback.
    final legacyDocumentRepairs = <String, String>{};
    final legacyDocumentCopies =
        <String, ({String sourcePath, String hash, String targetDirectory})>{};
    for (final oldFolder in legacyFolderPaths.entries) {
      if (replaceExisting) continue; // Replacement uses the validated ZIP bytes.
      final liveFolderId = folderIdMap[oldFolder.key]!;
      final targetDirectory = p.normalize(folderPath(oldFolder.key));
      for (final row in existingDocuments.where((candidate) =>
          candidate['folder_id'] == liveFolderId &&
          candidate['deleted_at'] == null)) {
        final documentId = row['id'] as String;
        final savedUri = row['storage_uri'] as String?;
        if (savedUri == null || savedUri.startsWith('missing://')) {
          // Keep the existing missing-document marker and never invent bytes.
          continue;
        }
        if (savedUri.startsWith('content://')) {
          throw StateError('Cannot automatically reconcile an SAF-backed PDF: ${row['name']}');
        }
        final sourcePath = p.normalize(p.absolute(savedUri.startsWith('file://')
            ? Uri.parse(savedUri).toFilePath() : savedUri));
        if (p.dirname(sourcePath) == targetDirectory) continue;
        if (p.dirname(sourcePath) != oldFolder.value) {
          throw StateError('PDF is outside the verified legacy folder: ${row['name']}');
        }
        if (await FileSystemEntity.type(sourcePath, followLinks: false) !=
            FileSystemEntityType.file) {
          throw StateError('Legacy PDF must be relinked manually: ${row['name']}');
        }
        final expected = row['sha256'] as String?;
        if (expected == null || expected.isEmpty) {
          throw StateError('Legacy PDF lacks an integrity checksum: ${row['name']}');
        }
        final actual = (await sha256.bind(File(sourcePath).openRead()).first).toString();
        if (actual != expected) {
          throw StateError('Legacy PDF SHA-256 mismatch: ${row['name']}');
        }
        final orphans = availableByFolderAndHash['$targetDirectory|$expected'] ??
            const <String>[];
        String? reusable;
        for (final candidate in orphans) {
          if (assignedPhysicalPaths.add(candidate)) {
            reusable = candidate;
            break;
          }
        }
        if (reusable != null) {
          legacyDocumentRepairs[documentId] = reusable;
        } else {
          legacyDocumentCopies[documentId] = (
            sourcePath: sourcePath, hash: expected,
            targetDirectory: targetDirectory,
          );
        }
      }
    }
    for (final row in rowsByTable['documents']!) {
      final id = row['id'] as String;
      if (duplicateDocumentIds.contains(id)) continue;
      final folderId = row['folder_id'] as String?;
      final targetDirectory = p.normalize(
          folderId == null ? unfiledRoot.path : folderPath(folderId));
      final hash = row['sha256'] as String?;
      if (hash == null) continue;
      final candidates = availableByFolderAndHash['$targetDirectory|$hash'] ??
          const <String>[];
      for (final candidate in candidates) {
        if (!assignedPhysicalPaths.add(candidate)) continue;
        restoredPaths[id] = candidate;
        break;
      }
    }
    final preview = <String, int>{
      'folders': folderRows.length,
      'matchedFolders': matchedFolderIds.length,
      'newFolders': folderPaths.values.where((path) => !Directory(path).existsSync()).length,
      'documents': rowsByTable['documents']!.length,
      'verifiedPdfs': duplicateDocumentIds.length + restoredPaths.length,
      'newPdfs': fileRows.where((row) => !duplicateDocumentIds.contains(row['documentId']) &&
          !restoredPaths.containsKey(row['documentId'])).length,
      'needsRelinking': rowsByTable['documents']!.where((row) =>
          !duplicateDocumentIds.contains(row['id']) && !restoredPaths.containsKey(row['id']) &&
          !backup.stagedPdfPaths.containsKey(row['id'])).length,
      'legacyFolderRepairs': legacyFolderPaths.length,
      'legacyPdfsToCopy': legacyDocumentCopies.length,
      'legacyPdfsReused': legacyDocumentRepairs.length,
      'conflicts': 0,
    };
    if (legacyFolderPaths.isNotEmpty && confirmPlan == null) {
      throw StateError('Legacy storage reconciliation requires explicit restore-preview approval.');
    }
    if (confirmPlan != null && !await confirmPlan(preview)) return null;
    // Generate a verified Full safety archive only after an accepted plan.
    // A cancelled preview must not create or prune backup files. This still
    // precedes all physical library writes and the SQLite transaction.
    await _createRestoreSafetyCheckpoint(
      mode: BackupRestoreMode.values.byName(restoreMode),
      sourceBackupId: (manifest['backupId'] ?? 'unknown').toString(),
    );
    // Durable journal precedes all library writes. Interrupted operations retain
    // their new files for verified reuse on retry; no broad recursive rollback.
    final journalDirectory = Directory(p.join(
        (await getApplicationSupportDirectory()).path, 'docsgrid', 'recovery', 'operations'));
    await journalDirectory.create(recursive: true);
    final journal = File(p.join(journalDirectory.path, '${_uuid.v4()}.jsonl'));
    // Append one intent per write instead of serializing an ever-growing list
    // (quadratic journal I/O on large libraries). Flush before physical writes.
    Future<void> writeJournal(String status, {String? documentId, String? expectedHash}) =>
        journal.writeAsString('${jsonEncode({
      'format': 'DocsGridRestoreOperation', 'version': 1,
      'backupId': manifest['backupId'], 'status': status,
      if (status == 'planned') 'folderPaths': folderPaths,
      if (status == 'creatingFolders') 'directory': createdDirectories.last,
      if (status == 'copying') ...{
        'destination': createdFiles.last, 'pending': pendingFiles.last,
        'documentId': documentId, 'sha256': expectedHash,
      },
    })}\n', mode: FileMode.append, flush: true).then((_) {});
    await writeJournal('planned');

    var databaseCommitted = false;
    var backupPayloadCopies = 0;
    try {
      for (final row in folderRows) {
        final directory = Directory(folderPath(row['id'] as String));
        if (!await directory.exists()) {
          createdDirectories.add(directory.path);
          await writeJournal('creatingFolders');
          await directory.create(recursive: true);
        }
      }
      // Copy old PDFs into the confirmed original folder before changing
      // any SQLite pointer. Journal, checksum and atomic rename each copy.
      // Never delete any source in Restored_... (separate cleanup permission).
      for (final entry in legacyDocumentCopies.entries) {
        final source = File(entry.value.sourcePath);
        final target = File(p.join(entry.value.targetDirectory,
            '${_uuid.v4()}_${p.basename(source.path)}'));
        final pending = File('${target.path}.pending');
        createdFiles.add(target.path);
        pendingFiles.add(pending.path);
        await writeJournal('copying',
            documentId: entry.key, expectedHash: entry.value.hash);
        await source.copy(pending.path);
        final actual = (await sha256.bind(pending.openRead()).first).toString();
        if (actual != entry.value.hash) {
          await pending.delete();
          throw StateError('Legacy PDF copy failed integrity verification.');
        }
        await pending.rename(target.path);
        legacyDocumentRepairs[entry.key] = target.path;
      }
      for (final item in fileRows) {
        final id = item['documentId'] as String;
        if (duplicateDocumentIds.contains(id) || restoredPaths.containsKey(id)) continue;
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
        final pendingFile = File('${destination.path}.pending');
        createdFiles.add(destination.path);
        pendingFiles.add(pendingFile.path);
        await writeJournal('copying', documentId: id, expectedHash: item['sha256'] as String);
        await File(stagedPath).copy(pendingFile.path);
        final digest = (await sha256.bind(pendingFile.openRead()).first).toString();
        if (digest != item['sha256']) {
          await pendingFile.delete();
          throw StateError('PDF integrity check failed during restore.');
        }
        await pendingFile.rename(destination.path);
        restoredPaths[id] = destination.path;
        backupPayloadCopies++;
      }

      for (final row in rowsByTable['documents']!) {
        final id = row['id'] as String;
        final uri = duplicateDocumentIds.contains(id)
            ? existingDocumentsById[documentIdMap[id]]!['storage_uri'] as String
            : restoredPaths[id];
        if (uri == null) continue; // Explicit database-only missing reference.
        final hash = uri.startsWith('content://')
            ? await StorageLocationService.instance.sha256Pdf(uri)
            : (await sha256.bind(File(uri.startsWith('file://')
                ? Uri.parse(uri).toFilePath() : uri).openRead()).first).toString();
        if (hash != row['sha256']) throw StateError('PDF changed during restore: ${row['name']}');
      }
      for (final path in folderPaths.values) {
        await Directory(path).list(followLinks: false).drain<void>();
      }
      await writeJournal('filesVerified');
      final restoredReminderRows = <Map<String, Object?>>[];
      await db.transaction((txn) async {
        final revision = await txn.query('portable_snapshot_state', columns: ['revision'], where: 'id = 1');
        if (revision.single['revision'] != inventoryRevision) {
          throw StateError('The library changed during restore preview. Retry to generate a fresh plan.');
        }
        if (replaceExisting) {
          // Dependent rows are removed before parents. SQLite rolls the
          // complete replacement back if any insert or constraint fails.
          for (final table in [
            'document_tags', 'reminders', 'history', 'document_text_index',
            'documents', 'categories', 'tags', 'settings', 'smart_collections',
          ]) {
            await txn.delete(table);
          }
          // folders.parent_id uses ON DELETE RESTRICT: remove descendants
          // before their parents rather than issuing one unsafe bulk delete.
          final existingFolderRows = await txn.query(
            'folders', columns: ['id', 'parent_id'],
          );
          for (final folder in BackupFolderGraphValidator.childFirst(existingFolderRows)) {
            await txn.delete('folders', where: 'id = ?', whereArgs: [folder['id']]);
          }
        }
        // Once physical copies have been verified, atomically publish their
        // existing document pointers with the corrected folder mappings.
        // Old physical copies remain untouched, including on rollback.
        if (!replaceExisting) {
          for (final entry in legacyDocumentRepairs.entries) {
            final updated = await txn.update('documents', {
              'storage_uri': entry.value,
              'relative_path': null,
            }, where: 'id = ? AND deleted_at IS NULL',
                whereArgs: [entry.key]);
            if (updated != 1) {
              throw StateError('The library changed while reconciling a legacy PDF.');
            }
          }
        }
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

        for (final row in BackupFolderGraphValidator.parentFirst(folderRows)) {
          final oldId = row['id'] as String;
          if (!replaceExisting && matchedFolderIds.contains(oldId)) {
            await txn.update('folders', {
              'storage_uri_or_relative_path': Platform.isAndroid
                  ? Uri.file(folderPath(oldId)).toString() : folderPath(oldId),
            }, where: 'id = ?', whereArgs: [folderIdMap[oldId]]);
            continue;
          }
          final copy = Map<String, Object?>.from(row);
          copy['id'] = folderIdMap[oldId];
          final oldParentId = row['parent_id'] as String?;
          copy['parent_id'] = oldParentId == null ? null : folderIdMap[oldParentId];
          // Folder storage columns contain URIs, not bare filesystem paths.
          // The restore tree is materialized with dart:io, so persist its path
          // as a file:// URI for Android's native storage dispatcher.
          copy['storage_uri_or_relative_path'] = Platform.isAndroid
              ? Uri.file(folderPath(oldId)).toString()
              : folderPath(oldId);
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
          final oldId = row['id'] as String;
          if (duplicateDocumentIds.contains(oldId)) continue;
          final copy = Map<String, Object?>.from(row);
          copy['id'] = documentIdMap[oldId];
          final oldFolderId = row['folder_id'] as String?;
          copy['folder_id'] = oldFolderId == null ? null : folderIdMap[oldFolderId];
          final oldCategoryId = row['category_id'] as String?;
          copy['category_id'] = oldCategoryId == null ? null : categoryIdMap[oldCategoryId];
          final restored = restoredPaths[oldId];
          final isDatabaseOnly = manifest['backupType'] == 'database';
          if (restored == null && !isDatabaseOnly) {
            throw StateError('Backup is missing PDF bytes for "${row['name']}".');
          }
          // Database-only restores recover document metadata and relationships
          // while marking unavailable PDF payloads for explicit relinking.
          copy['storage_uri'] = restored ?? 'missing://$oldId';
          copy['relative_path'] = null;
          if (restored == null) {
            final raw = copy['metadata_json'];
            final metadata = raw is String && raw.isNotEmpty
                ? Map<String, dynamic>.from(jsonDecode(raw) as Map) : <String, dynamic>{};
            metadata['docsGridRecoveryStatus'] = 'pdf_missing_relink_required';
            copy['metadata_json'] = jsonEncode(metadata);
          }
          if (repairDocumentIds.contains(oldId)) {
            await txn.update('documents', {
              'storage_uri': copy['storage_uri'], 'relative_path': null,
              'metadata_json': copy['metadata_json'],
            }, where: 'id = ?', whereArgs: [documentIdMap[oldId]]);
          } else {
            queueInsert('documents', copy);
          }
          if (pending >= 500) await flushBatch();
        }
        for (final row in rowsByTable['document_tags']!) {
          final oldTagId = row['tag_id'] as String;
          final oldDocumentId = row['document_id'] as String;
          final mappedTagId = tagIdMap[oldTagId];
          final mappedDocumentId = documentIdMap[oldDocumentId];
          if (mappedTagId == null || mappedDocumentId == null) {
            throw StateError('Backup contains an unknown document or tag reference.');
          }
          queueInsert('document_tags', {
            ...row,
            'document_id': mappedDocumentId,
            'tag_id': mappedTagId,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          if (pending >= 500) await flushBatch();
        }
        final existingReminderIds = replaceExisting
            ? <String>{}
            : (await txn.query('reminders', columns: ['id']))
                .map((row) => row['id'] as String).toSet();
        final existingHistoryIds = replaceExisting
            ? <String>{}
            : (await txn.query('history', columns: ['id']))
                .map((row) => row['id'] as String).toSet();
        for (final row in rowsByTable['reminders']!) {
          final copy = Map<String, Object?>.from(row);
          final oldId = row['id'] as String;
          copy['id'] = oldId;
          final oldDocumentId = row['document_id'] as String?;
          copy['document_id'] = oldDocumentId == null
              ? null
              : (documentIdMap[oldDocumentId] ?? oldDocumentId);
          if (existingReminderIds.contains(oldId)) {
            final current = (await txn.query('reminders', where: 'id = ?', whereArgs: [oldId])).single;
            if (copy.entries.any((entry) => current[entry.key] != entry.value)) {
              throw StateError('reminders identity conflict: $oldId. Existing metadata was preserved.');
            }
            continue;
          }
          queueInsert('reminders', copy);
          restoredReminderRows.add(copy);
          existingReminderIds.add(copy['id'] as String);
          if (pending >= 500) await flushBatch();
        }
        for (final row in rowsByTable['history']!) {
          final copy = Map<String, Object?>.from(row);
          final oldId = row['id'] as String;
          copy['id'] = oldId;
          final oldDocumentId = row['document_id'] as String?;
          copy['document_id'] = oldDocumentId == null
              ? null
              : (documentIdMap[oldDocumentId] ?? oldDocumentId);
          if (existingHistoryIds.contains(oldId)) {
            final current = (await txn.query('history', where: 'id = ?', whereArgs: [oldId])).single;
            if (copy.entries.any((entry) => current[entry.key] != entry.value)) {
              throw StateError('history identity conflict: $oldId. Existing metadata was preserved.');
            }
            continue;
          }
          queueInsert('history', copy);
          existingHistoryIds.add(copy['id'] as String);
          if (pending >= 500) await flushBatch();
        }
        for (final row in rowsByTable['document_text_index']!) {
          final oldDocumentId = row['document_id'] as String;
          if (duplicateDocumentIds.contains(oldDocumentId)) continue;
          // Selective OCR-only restore may target an existing document without
          // importing its document row; preserve that live document ID.
          final mappedDocumentId = documentIdMap[oldDocumentId] ??
              (externalDocumentIds.contains(oldDocumentId) ? oldDocumentId : null);
          if (mappedDocumentId == null) continue;
          queueInsert('document_text_index', {
            ...row,
            'document_id': mappedDocumentId,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
          if (pending >= 500) await flushBatch();
        }
        // Collections are user-authored saved views. Keep an existing same-name
        // collection during merge; otherwise remap an ID collision instead of
        // allowing one saved collection to overwrite another.
        final existingCollections = await txn.query(
          'smart_collections', columns: ['id', 'name'],
        );
        final existingCollectionIds = existingCollections
            .map((row) => row['id'] as String).toSet();
        final existingCollectionNames = existingCollections
            .map((row) => (row['name'] as String).toLowerCase()).toSet();
        for (final row in rowsByTable['smart_collections']!) {
          final name = row['name'] as String;
          if (existingCollectionNames.contains(name.toLowerCase())) continue;
          final oldId = row['id'] as String;
          final copy = Map<String, Object?>.from(row)
            ..['id'] = existingCollectionIds.contains(oldId) ? _uuid.v4() : oldId;
          queueInsert('smart_collections', copy);
          existingCollectionIds.add(copy['id'] as String);
          existingCollectionNames.add(name.toLowerCase());
          if (pending >= 500) await flushBatch();
        }
        // Preferences are additive: never overwrite settings already configured
        // on this device when importing a backup from another installation.
        for (final row in rowsByTable['settings']!) {
          queueInsert('settings', row, conflictAlgorithm: ConflictAlgorithm.ignore);
          if (pending >= 500) await flushBatch();
        }
        await flushBatch();
        if ((await txn.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
          throw StateError('Restored database contains inconsistent references.');
        }
        for (final entry in folderIdMap.entries) {
          final actual = (await txn.query('folders',
              where: 'id = ?', whereArgs: [entry.value])).single;
          final expected = Platform.isAndroid
              ? Uri.file(folderPath(entry.key)).toString() : folderPath(entry.key);
          if (actual['storage_uri_or_relative_path'] != expected) {
            throw StateError('Restored folder mapping did not verify.');
          }
        }
      });
      databaseCommitted = true;
      try { await writeJournal('committed'); } catch (_) { /* DB is authoritative. */ }
      for (final row in restoredReminderRows) {
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
      try {
        final locations = await StorageLocationService.instance.portableDataLocationsIfAvailable();
        final recoveryUri = locations['restoreReportsUri'] ?? locations['recoveryUri'];
        if (recoveryUri != null) {
          final report = <String, Object?>{
            'format': 'DocsGridRestoreReport',
            'version': 1,
            'status': 'completed',
            'mode': restoreMode,
            'backupId': manifest['backupId'],
            'backupCreatedAt': manifest['createdAt'],
            'completedAtUtc': DateTime.now().toUtc().toIso8601String(),
            'pdfPayloadsRestored': backupPayloadCopies,
            'legacyPdfsRelinked': legacyDocumentRepairs.length,
            'verifiedPdfsReused': restoredPaths.length - backupPayloadCopies + duplicateDocumentIds.length,
            'needsRelinking': preview['needsRelinking'],
            'documentsInArchive': rowsByTable['documents']!.length,
            'foldersInArchive': rowsByTable['folders']!.length,
            'categoriesInArchive': rowsByTable['categories']!.length,
            'tagsInArchive': rowsByTable['tags']!.length,
            'remindersImported': restoredReminderRows.length,
            'historyImported': rowsByTable['history']!.length,
            'settingsImported': rowsByTable['settings']!.length,
          };
          await StorageLocationService.instance.writeTextFile(
            parentUri: recoveryUri,
            name: 'restore_${DateTime.now().toUtc().millisecondsSinceEpoch}_${_uuid.v4()}.json',
            contents: jsonEncode(report),
          );
        }
      } catch (_) {
        // A report write failure must not roll back an already committed restore.
      }
      return backupPayloadCopies;
    } catch (_) {
      if (!databaseCommitted) {
        for (final path in [...createdFiles, ...pendingFiles]) {
          try { if (await File(path).exists()) await File(path).delete(); } catch (_) {}
        }
        for (final path in createdDirectories.reversed) {
          try {
            final directory = Directory(path);
            if (await directory.exists() && await directory.list().isEmpty) await directory.delete();
          } catch (_) {}
        }
        await writeJournal('rolledBack');
      }
      rethrow;
    }
  }

  /// Writes a versioned, verified metadata snapshot into the user-selected
  /// DocsGrid/System/Database folder. PDF bytes remain in the library folder;
  /// documents.json retains their relative paths and SHA-256 values.
  Future<String> createPortableMetadataSnapshot() =>
      _withRecoveryLock(() async {
        try {
          final name = await _createPortableMetadataSnapshotLocked();
          snapshotDiagnostics = {
            ...snapshotDiagnostics,
            'lastCreationResult': 'verified',
            'lastSnapshotName': name,
            'creationError': null,
          };
          return name;
        } catch (error) {
          // Diagnostics must not claim an earlier success was the latest
          // result when this creation attempt failed.
          snapshotDiagnostics = {
            ...snapshotDiagnostics,
            'lastCreationResult': 'failed',
            'creationErrorType': error.runtimeType.toString(),
          };
          rethrow;
        }
      });

  Future<String> _createPortableMetadataSnapshotLocked() async {
    await StorageMigrationGate.waitUntilReady();
    final locations = await (_snapshotLocations?.call() ??
        StorageLocationService.instance.portableDataLocationsIfAvailable());
    if (locations['databaseUri'] == null) {
      throw StateError('Portable Database folder is not available. Enable storage access or select an existing recovery tree.');
    }
    final db = await _database.database;
    // Read every durable table and its revision in one SQLite read transaction.
    // This prevents a snapshot whose documents, folders and reminders came from
    // different moments while the user is changing the library.
    final tableNames = PortableSnapshotManifest.supportedTableNames;
    final snapshotCapture = await db.transaction((txn) async {
      final revisionRows = await txn.query(
        'portable_snapshot_state',
        columns: ['revision'],
        where: 'id = 1',
        limit: 1,
      );
      if (revisionRows.isEmpty) {
        throw StateError('Portable snapshot state is not initialized.');
      }
      final rowsByTable = <String, List<Map<String, Object?>>>{};
      for (final table in tableNames) {
        rowsByTable[table] = await txn.query(table);
      }
      return (
        revision: revisionRows.single['revision'] as int,
        rowsByTable: rowsByTable,
      );
    });
    final state = await db.query('portable_snapshot_state', where: 'id = 1');
    if (state.isNotEmpty &&
        state.single['last_snapshot_revision'] == snapshotCapture.revision &&
        state.single['last_snapshot_name'] is String) {
      final lastName = state.single['last_snapshot_name'] as String;
      // A clean DB revision does not prove the last exported snapshot still
      // exists or is readable. For explicit snapshot requests, verify the
      // published recovery point before skipping another export. Never prune
      // or overwrite an invalid/missing older snapshot here.
      try {
        final entries = await StorageLocationService.instance
            .listDirectory(locations['databaseUri']!);
        final matching = entries.where((entry) =>
            entry['name'] == lastName && entry['isDirectory'] == true).toList();
        if (matching.length == 1) {
          final verified = await _readVerifiedSnapshot(matching.single['uri'] as String);
          PortableSnapshotRowsValidator.validate(
              verified['rows'] as Map<String, List<Map<String, Object?>>>);
          final manifest = jsonDecode(verified['manifestText'] as String) as Map;
          if (manifest['portableDataRevision'] == snapshotCapture.revision) {
            return lastName;
          }
        }
      } catch (_) {
        // Missing, corrupt or inaccessible recovery points need a fresh
        // verified snapshot, not a misleading "already current" result.
      }
    }
    final capturedRevision = snapshotCapture.revision;
    final capturedRows = snapshotCapture.rowsByTable;
    if (!tableNames.contains('documents') || !tableNames.contains('folders')) {
      throw StateError('The DocsGrid database is incomplete; no snapshot was written.');
    }

    final stamp = DateTime.now().toUtc().toIso8601String()
        .replaceAll(':', '-').replaceAll('.', '-');
    final snapshotName = 'snapshot_${stamp}_${_uuid.v4()}';
    final snapshotUri = await StorageLocationService.instance.createDirectory(
      parentUri: locations['databaseUri']!,
      name: snapshotName,
    );
    final fileRecords = <Map<String, Object?>>[];
    final recordCounts = <String, int>{};

    try {
      await StorageLocationService.instance.writeTextFile(
        parentUri: snapshotUri, name: 'operation.json', contents: jsonEncode({
          'format': 'DocsGridSnapshotOperation', 'version': 1,
          'directoryName': snapshotName,
          'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      for (final table in tableNames) {
        final rows = capturedRows[table]!;
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
        'portableDataRevision': capturedRevision,
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
      // Validate published bytes and every supported relationship before
      // marking the captured revision clean or pruning older recovery points.
      final verifiedExport = await _readVerifiedSnapshot(snapshotUri);
      PortableSnapshotRowsValidator.validate(
          verifiedExport['rows'] as Map<String, List<Map<String, Object?>>>);
      // If any durable record changed during export, the revision mismatch
      // deliberately leaves the snapshot dirty for the next coalesced pass.
      await _database.markPortableSnapshotClean(
        capturedRevision: capturedRevision,
        snapshotName: snapshotName,
      );
      try {
        await _prunePortableSnapshots(locations['databaseUri']!, snapshotUri);
      } catch (error) {
        snapshotDiagnostics = {...snapshotDiagnostics, 'cleanupError': '$error'};
      }
      return snapshotName;
    } catch (_) {
      // Keep the incomplete directory for diagnostics; without manifest it
      // cannot be selected as a valid recovery snapshot.
      rethrow;
    }
  }

  Future<Map<String, Object?>> _readVerifiedSnapshot(String snapshotUri) async {
    final storage = StorageLocationService.instance;
        final manifestText = await storage.readTextFile(
          await _findChildUri(snapshotUri, 'manifest.json'),
        );
        final manifest = PortableSnapshotManifest.parse(manifestText);
        final rowsByTable = <String, List<Map<String, Object?>>>{};
        for (final record in manifest.files) {
          final table = record.path.substring(0, record.path.length - 5);
          if (!PortableSnapshotManifest.supportedTableNames.contains(table)) {
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

    PortableSnapshotManifest.validateRelations(rowsByTable);
    return {'manifestText': manifestText, 'manifest': manifest,
      'rows': rowsByTable, 'documents': documentRows.length,
      'records': rowsByTable.values.fold<int>(0, (n, rows) => n + rows.length)};
  }

  /// Internal diagnostics; no additional dashboard or snapshot format change.
  static Map<String, Object?> snapshotDiagnostics = {};

  Future<void> _prunePortableSnapshots(String databaseUri, String publishedUri) async {
    final storage = StorageLocationService.instance;
    final entries = await storage.listDirectory(databaseUri);
    final points = <VerifiedSnapshotPoint>[];
    final manifests = <String, PortableSnapshotManifest>{};
    var invalid = 0;
    var totalBytes = 0;
    for (final entry in entries) {
      if (entry['isDirectory'] != true ||
          !(entry['name'] as String? ?? '').startsWith('snapshot_')) continue;
      try {
        final uri = entry['uri'] as String;
        final verified = await _readVerifiedSnapshot(uri);
        PortableSnapshotRowsValidator.validate(
          verified['rows'] as Map<String, List<Map<String, Object?>>>);
        final raw = jsonDecode(verified['manifestText'] as String) as Map;
        // Missing ownership/time data in legacy snapshots means retain, not delete.
        if (raw['app'] != 'DocsGrid' || raw['createdAtUtc'] is! String ||
            !(raw['createdAtUtc'] as String).endsWith('Z')) continue;
        final at = DateTime.parse(raw['createdAtUtc'] as String);
        final manifest = verified['manifest'] as PortableSnapshotManifest;
        final children = await storage.listDirectory(uri);
        // Legacy copies without our explicit operation marker remain readable
        // recovery points, but are NOT eligible for automatic deletion.
        if (!children.any((child) => child['name'] == 'operation.json')) continue;
        final marker = jsonDecode(await storage.readTextFile(
            await _findChildUri(uri, 'operation.json')));
        if (marker is! Map || marker['format'] != 'DocsGridSnapshotOperation' ||
            marker['version'] != 1 || marker['directoryName'] != entry['name']) continue;
        final expected = {'manifest.json', ...manifest.files.map((f) => f.path),
          if (children.any((child) => child['name'] == 'operation.json')) 'operation.json'};
        if (children.length != expected.length || children.any((child) =>
            child['isDirectory'] == true || !expected.contains(child['name']))) continue;
        final bytes = manifest.files.fold<int>(0, (n, file) => n + file.sizeBytes) +
            utf8.encode(verified['manifestText'] as String).length;
        totalBytes += bytes;
        points.add(VerifiedSnapshotPoint(uri: uri, createdAt: at,
            documentCount: verified['documents'] as int, sizeBytes: bytes));
        manifests[uri] = manifest;
      } catch (_) { invalid++; }
    }
    final keep = const PortableSnapshotRetention().keep(points, DateTime.now(),
        protectedUris: {publishedUri});
    var freed = 0;
    var removed = 0;
    // The same gate protects the complete restore, not just snapshot selection.
    // Only file-backed snapshots can be removed safely without provider-specific
    // recursive-delete races. SAF and all unknown/incomplete directories remain.
    for (final point in points) {
      if (keep.contains(point.uri) || !point.uri.startsWith('file://')) continue;
      final directory = Directory.fromUri(Uri.parse(point.uri));
      try {
        if (await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory) continue;
        final children = await directory.list(followLinks: false).toList();
        final expected = {'manifest.json', ...manifests[point.uri]!.files.map((f) => f.path),
          if (children.any((child) => p.basename(child.path) == 'operation.json')) 'operation.json'};
        if (children.length != expected.length || children.any((child) =>
            child is! File || !expected.contains(p.basename(child.path)))) continue;
        await _readVerifiedSnapshot(point.uri);
        // Invalidate recovery first. Never recursively remove an unknown child.
        await File(p.join(directory.path, 'manifest.json')).delete();
        for (final file in manifests[point.uri]!.files) {
          await File(p.join(directory.path, file.path)).delete();
        }
        final operation = File(p.join(directory.path, 'operation.json'));
        if (await operation.exists()) await operation.delete();
        await directory.delete();
        freed += point.sizeBytes;
        removed++;
      } catch (_) { break; } // Fail closed; leave all other recovery points.
    }
    if (points.length - removed >= 2) {
      for (final entry in entries) {
        if (entry['isDirectory'] != true ||
            !(entry['name'] as String? ?? '').startsWith('snapshot_')) continue;
        final uri = entry['uri'] as String;
        if (!uri.startsWith('file://')) continue;
        final directory = Directory.fromUri(Uri.parse(uri));
        try {
          if (await FileSystemEntity.type(directory.path, followLinks: false) !=
              FileSystemEntityType.directory) continue;
          final children = await directory.list(followLinks: false).toList();
          final allowed = {'operation.json',
            ...PortableSnapshotManifest.supportedTableNames.map((name) => '$name.json')};
          if (children.any((child) => child is! File || !allowed.contains(p.basename(child.path)))) continue;
          final marker = File(p.join(directory.path, 'operation.json'));
          final value = jsonDecode(await marker.readAsString());
          if (value is! Map || value['format'] != 'DocsGridSnapshotOperation' ||
              value['version'] != 1 || value['directoryName'] != entry['name'] ||
              value['createdAtUtc'] is! String || !(value['createdAtUtc'] as String).endsWith('Z')) continue;
          final age = DateTime.now().toUtc().difference(DateTime.parse(value['createdAtUtc'] as String));
          if (age < const Duration(hours: 48)) continue;
          // Recheck completion immediately before deleting enumerated metadata.
          if (await File(p.join(directory.path, 'manifest.json')).exists()) continue;
          for (final child in children.where((child) => child.path != marker.path)) {
            await child.delete();
          }
          await marker.delete();
          await directory.delete();
        } catch (_) { /* Unknown, future-dated and inaccessible data survives. */ }
      }
    }
    final times = points.map((point) => point.createdAt).toList()..sort();
    snapshotDiagnostics = {
      'snapshotDirectories': entries.where((e) => e['isDirectory'] == true &&
          (e['name'] as String? ?? '').startsWith('snapshot_')).length,
      'verifiedSnapshots': points.length, 'invalidOrIncomplete': invalid,
      'verifiedBytesBeforeCleanup': totalBytes, 'freedBytes': freed,
      'removedSnapshots': removed, 'lastCreationResult': 'verified',
      'oldestUtc': times.isEmpty ? null : times.first.toIso8601String(),
      'newestUtc': times.isEmpty ? null : times.last.toIso8601String(),
    };
  }

  /// Returns the newest fully verified snapshot, skipping incomplete or
  /// damaged snapshots left by an interrupted export. A broken newest folder
  /// must not hide an older recoverable snapshot.
  Future<Map<String, Object?>?> _findLatestVerifiedPortableSnapshot() async {
    final storage = StorageLocationService.instance;
    final locations = await storage.portableDataLocations();
    final databaseUris = <String>[locations['databaseUri']!];
    final legacyUri = locations['legacyRootUri'];
    if (legacyUri != null && legacyUri.startsWith('file://')) {
      final legacyRoot = Uri.parse(legacyUri).toFilePath();
      for (final path in [
        p.join(legacyRoot, 'Database'),
        p.join(legacyRoot, 'System', 'Database'),
      ]) {
        final directory = Directory(path);
        if (await directory.exists()) {
          databaseUris.add(Uri.directory(directory.path).toString());
        }
      }
    }
    final snapshots = <Map<String, Object?>>[];
    for (final databaseUri in databaseUris.toSet()) {
      try {
        final children = await storage.listDirectory(databaseUri);
        snapshots.addAll(children.where((entry) =>
            entry['isDirectory'] == true &&
            entry['name'] is String &&
            (entry['name'] as String).startsWith('snapshot_')));
      } catch (_) {
        // One missing legacy location must not hide valid snapshots elsewhere.
      }
    }
    snapshots.sort((a, b) =>
        (b['name'] as String).compareTo(a['name'] as String));

    // A reinstall can create a newer, valid-but-empty snapshot before the
    // previous portable tree is selected. Timestamp-only selection would then
    // restore built-in folders/categories from the empty install and silently
    // ignore the older snapshot containing the user's PDFs and metadata.
    // Validate every candidate and prefer the snapshot with the most document
    // records, then the most total records; use timestamp only as a tie-breaker.
    Map<String, Object?>? bestSnapshot;
    var bestDocumentCount = -1;
    var bestRecordCount = -1;
    var bestCreatedAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

    for (final snapshot in snapshots) {
      try {
        final snapshotUri = snapshot['uri'] as String;
        final verified = await _readVerifiedSnapshot(snapshotUri);
        final manifestText = verified['manifestText'] as String;
        final manifest = verified['manifest'] as PortableSnapshotManifest;
        final rowsByTable = verified['rows'] as Map<String, List<Map<String, Object?>>>;
        final documentRows = rowsByTable['documents']!;
        final documentCount = documentRows.length;
        final recordCount = rowsByTable.values.fold<int>(
          0,
          (total, rows) => total + rows.length,
        );
        final rawManifest = jsonDecode(manifestText) as Map;
        final createdAt = DateTime.tryParse(rawManifest['createdAtUtc'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        final isBetter = documentCount > bestDocumentCount ||
            (documentCount == bestDocumentCount &&
                (recordCount > bestRecordCount ||
                 (recordCount == bestRecordCount && createdAt.isAfter(bestCreatedAt))));
        if (isBetter) {
          bestDocumentCount = documentCount;
          bestRecordCount = recordCount;
          bestCreatedAt = createdAt;
          bestSnapshot = {
            'name': snapshot['name'] as String,
            'uri': snapshotUri,
            'manifestText': manifestText,
            'manifest': manifest,
          };
        }
      } catch (_) {
        // Try the next older snapshot. Never mutate or delete a failed copy.
      }
    }
    return bestSnapshot;
  }

  Future<String?> verifyLatestPortableMetadataSnapshot() =>
      _withRecoveryLock(() async {
        final snapshot = await _findLatestVerifiedPortableSnapshot();
        return snapshot?['name'] as String?;
      });

  /// Restores the newest portable snapshot additively. Existing records are
  /// retained; imported IDs are remapped where needed. PDFs are relinked by
  /// SHA-256 from the currently selected library and are never overwritten.
  Future<Map<String, int>> restoreLatestPortableMetadataSnapshot({
    void Function(int completed, int total)? onProgress,
  }) => _withRecoveryLock(() =>
      _restoreLatestPortableMetadataSnapshotLocked(onProgress: onProgress));

  Future<Map<String, int>> _restoreLatestPortableMetadataSnapshotLocked({
    void Function(int completed, int total)? onProgress,
  }) async {
    await StorageMigrationGate.waitUntilReady();
    final storage = StorageLocationService.instance;
    final locations = await storage.portableDataLocations();
    final snapshot = await _findLatestVerifiedPortableSnapshot();
    if (snapshot == null) {
      throw StateError('No complete, verified portable recovery snapshot was found.');
    }
    final snapshotUri = snapshot['uri'] as String;
    final manifest = snapshot['manifest'] as PortableSnapshotManifest;
    if (manifest.databaseSchemaVersion > BackupSchemaCompatibility.currentVersion) {
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
      if (!PortableSnapshotManifest.supportedTableNames.contains(table)) {
        throw StateError('Snapshot contains unsupported table: $table.');
      }
      rowsByTable[table] = decoded
          .map((value) => Map<String, Object?>.from(value as Map))
          .toList();
    }
    for (final required in ['folders', 'documents', 'categories', 'tags',
      'document_tags', 'reminders', 'history', 'settings', 'document_text_index',
      'smart_collections']) {
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
    // Portable snapshots keep folder metadata under Folders/ but the actual
    // PDF payloads are stored under Documents/. Search both trees so a
    // recovery import can relink the original PDFs instead of restoring only
    // empty metadata records.
    final pending = <String>[
      locations['libraryUri']!,
      if (locations['documentsUri'] != null)
        locations['documentsUri']!,
    ];

    // A reinstall may initialize a new canonical com.docsgrid root while the
    // previous release's managed PDFs remain in Android/media/DocsGrid.
    // Metadata snapshots are portable across that migration, so hash matching
    // must search the explicitly whitelisted legacy library directories too.
    // Never scan the legacy root itself: it also contains backups, snapshots,
    // caches and unrelated recovery data.
    final legacyRootUri = locations['legacyRootUri'];
    if (Platform.isAndroid &&
        legacyRootUri != null &&
        legacyRootUri.startsWith('file://')) {
      final legacyRoot = Directory(Uri.parse(legacyRootUri).toFilePath());
      for (final legacy in DocumentToolsService.legacyManagedRecoveryPaths(
        legacyRoot.path,
      )) {
        final directory = Directory(legacy.path);
        if (await directory.exists()) {
          pending.add(Uri.directory(directory.path).toString());
        }
      }
    }

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
    // Metadata entities are restored from the same verified snapshot as PDFs.
    // Report source record counts separately so the UI does not imply that
    // reminders/tags/categories are physical files.
    final recoveredCounts = <String, int>{
      'folders': folderRows.length,
      'categories': rowsByTable['categories']!.length,
      'tags': rowsByTable['tags']!.length,
      'documentTags': rowsByTable['document_tags']!.length,
      'reminders': rowsByTable['reminders']!.length,
      'activity': rowsByTable['history']!.length,
      'ocrIndexes': rowsByTable['document_text_index']!.length,
      'settings': rowsByTable['settings']!.length,
    };
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

    // Some Android/OEM backup flows may restore the app-private SQLite DB on
    // reinstall while leaving its former PDF storage paths unavailable. Track
    // those rows before the import transaction so a stale existing ID is never
    // reported as a successful link merely because the DB row already exists.
    final usableExistingDocumentIds = <String>{};
    for (final row in rowsByTable['documents']!) {
      final oldId = row['id'] as String;
      final mappedId = documentIdMap[oldId]!;
      if (!existingDocuments.any((value) => value['id'] == mappedId)) continue;
      final digest = row['sha256'] as String?;
      if (digest != null && pdfUris.containsKey(digest)) continue;
      final existing = existingDocuments.firstWhere(
        (value) => value['id'] == mappedId,
      );
      final uri = existing['storage_uri'] as String?;
      if (uri == null || uri.isEmpty || uri.startsWith('missing://')) continue;
      try {
        final actualDigest = uri.startsWith('content://') || uri.startsWith('file://')
            ? await storage.sha256Pdf(uri)
            : (await sha256.bind(File(uri).openRead()).first).toString();
        if (digest == null || digest == actualDigest) {
          usableExistingDocumentIds.add(mappedId);
        }
      } catch (_) {
        // Missing, revoked or unreadable old paths remain explicitly relinkable.
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
          final existing = existingDocuments.firstWhere(
            (value) => value['id'] == newId,
          );
          if (linkedUri != null ||
              usableExistingDocumentIds.contains(newId)) {
            // Clear an old relink-required marker when the existing source is
            // verified or a SHA-256-matching replacement has been discovered.
            final metadata = <String, dynamic>{};
            final oldMetadata = existing['metadata_json'];
            if (oldMetadata is String && oldMetadata.isNotEmpty) {
              try {
                final decoded = jsonDecode(oldMetadata);
                if (decoded is Map) {
                  metadata.addAll(Map<String, dynamic>.from(decoded));
                }
              } catch (_) {}
            }
            metadata.remove('docsGridRecoveryStatus');
            await txn.update('documents', {
              if (linkedUri != null) 'storage_uri': linkedUri,
              if (linkedUri != null) 'relative_path': null,
              'metadata_json': jsonEncode(metadata),
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            }, where: 'id = ?', whereArgs: [newId]);
            linkedDocuments++;
          } else {
            missingPdfs++;
            final metadata = <String, dynamic>{};
            final oldMetadata = existing['metadata_json'];
            if (oldMetadata is String && oldMetadata.isNotEmpty) {
              try {
                final decoded = jsonDecode(oldMetadata);
                if (decoded is Map) {
                  metadata.addAll(Map<String, dynamic>.from(decoded));
                }
              } catch (_) {}
            }
            metadata['docsGridRecoveryStatus'] = 'pdf_missing_relink_required';
            await txn.update('documents', {
              'metadata_json': jsonEncode(metadata),
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            }, where: 'id = ?', whereArgs: [newId]);
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
      final existingCollectionNames = (await txn.query(
        'smart_collections', columns: ['name'],
      )).map((row) => (row['name'] as String).toLowerCase()).toSet();
      final existingCollectionIds = (await txn.query(
        'smart_collections', columns: ['id'],
      )).map((row) => row['id'] as String).toSet();
      for (final row in rowsByTable['smart_collections']!) {
        final name = row['name'] as String;
        if (existingCollectionNames.contains(name.toLowerCase())) continue;
        final id = row['id'] as String;
        await txn.insert('smart_collections', {
          ...row,
          'id': existingCollectionIds.contains(id) ? _uuid.v4() : id,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        existingCollectionNames.add(name.toLowerCase());
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
    if (rowsByTable['documents']!.isEmpty) {
      final phoneRecovery = await recoverLoosePortablePdfs(onProgress: onProgress);
      addedDocuments += phoneRecovery['added'] ?? 0;
      recoveredCounts['folders'] =
          (recoveredCounts['folders'] ?? 0) + (phoneRecovery['folders'] ?? 0);
    }
    return {
      'documentsAdded': addedDocuments,
      'documentsLinked': linkedDocuments,
      'pdfsMissing': missingPdfs,
      ...recoveredCounts,
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
            name.startsWith('/') || name.contains(String.fromCharCode(92)) ||
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
      final schemaVersion = manifest['databaseSchemaVersion'];
      if (schemaVersion != null) {
        if (schemaVersion is! int) {
          throw StateError('Backup database schema version is invalid.');
        }
        try {
          BackupSchemaCompatibility.requireSupported(schemaVersion);
        } on FormatException catch (error) {
          throw StateError(error.message);
        }
      }
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

      final metadataFiles = manifest['metadataFiles'];
      if (metadataFiles != null) {
        if (metadataFiles is! List) {
          throw StateError('Backup metadata file checksums are invalid.');
        }
        final seenMetadata = <String>{};
        for (final raw in metadataFiles) {
          if (raw is! Map || raw['entry'] is! String ||
              raw['sizeBytes'] is! int || raw['sha256'] is! String ||
              !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(raw['sha256'] as String)) {
            throw StateError('Backup metadata file checksums are invalid.');
          }
          final name = raw['entry'] as String;
          if (!seenMetadata.add(name) || !name.endsWith('.json') ||
              name.contains('/') || name.contains(String.fromCharCode(92))) {
            throw StateError('Backup contains an unsafe metadata checksum path.');
          }
          final entry = decoded.findFile(name);
          if (entry == null || !entry.isFile || entry.isSymbolicLink) {
            throw StateError('Backup metadata entry is missing: $name.');
          }
          final bytes = entry.content as List<int>;
          if (bytes.length != raw['sizeBytes'] ||
              sha256.convert(bytes).toString() != (raw['sha256'] as String).toLowerCase()) {
            throw StateError('Backup metadata integrity check failed for $name.');
          }
        }
        final declaredMetadataEntries = archiveNames
            .where((name) => name.endsWith('.json') && name != 'manifest.json')
            .toSet();
        if (!seenMetadata.containsAll(declaredMetadataEntries) ||
            !declaredMetadataEntries.containsAll(seenMetadata)) {
          throw StateError('Backup is missing a metadata checksum or contains an unreferenced metadata checksum.');
        }
      }
      const tableNames = <String>[
        'folders', 'documents', 'categories', 'tags', 'document_tags',
        'reminders', 'history', 'settings', 'document_text_index',
        'smart_collections',
      ];
      final rowsByTable = <String, List<Map<String, Object?>>>{};
      for (final table in tableNames) {
        final tableFile = decoded.findFile('$table.json');
        if (tableFile == null &&
            (table == 'document_text_index' || table == 'smart_collections') &&
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
      final locations = Platform.isAndroid
          ? await StorageLocationService.instance.portableDataLocationsIfAvailable()
          : const <String, String>{};
      final temporaryUri = locations['tempUri'];
      final temporaryDirectory = temporaryUri != null && temporaryUri.startsWith('file://')
          ? Directory(Uri.parse(temporaryUri).toFilePath())
          : Directory.systemTemp;
      await temporaryDirectory.create(recursive: true);
      staging = await temporaryDirectory.createTemp('docsgrid_restore_');
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
      final databaseOnly = manifest['backupType'] == 'database';
      if (!databaseOnly &&
          (seenDocuments.length != documentIds.length ||
           !seenDocuments.containsAll(documentIds))) {
        throw StateError('Backup contains orphaned PDF entries: every document must have exactly one PDF entry.');
      }
      if (databaseOnly && rawFiles.isNotEmpty) {
        throw StateError('Database-only backup must not contain PDF payload entries.');
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



/// Raised when the OCR owner route is dismissed before indexing completes.
class OcrIndexCancelled implements Exception {
  const OcrIndexCancelled();
  @override
  String toString() => 'OCR indexing was cancelled because its screen was closed.';
}
