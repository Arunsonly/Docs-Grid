import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/storage/storage_location_service.dart';
import '../../folders/data/folder_repository.dart';

class DocumentRecord {
  const DocumentRecord({
    required this.id,
    required this.name,
    required this.storagePath,
    required this.sizeBytes,
    required this.createdAt,
    required this.isFavorite,
    this.categoryId,
    this.categoryName,
    this.tagNames = const [],
    this.folderId,
  });

  final String id;
  final String name;
  final String storagePath;
  final int sizeBytes;
  final DateTime createdAt;
  final bool isFavorite;
  final String? categoryId;
  final String? categoryName;
  final List<String> tagNames;
  final String? folderId;

  factory DocumentRecord.fromMap(Map<String, Object?> row) {
    final metadata = jsonDecode((row['metadata_json'] as String?) ?? '{}')
        as Map<String, dynamic>;
    return DocumentRecord(
      id: row['id'] as String,
      name: row['name'] as String,
      storagePath: (row['storage_uri'] as String?) ?? '',
      sizeBytes: (row['size_bytes'] as int?) ?? 0,
      createdAt: DateTime.parse(row['created_at'] as String),
      isFavorite: metadata['favorite'] == true,
      categoryId: row['category_id'] as String?,
      categoryName: row['category_name'] as String?,
      tagNames: ((row['tag_names'] as String?) ?? '').isEmpty
          ? const []
          : (row['tag_names'] as String).split(', '),
      folderId: row['folder_id'] as String?,
    );
  }
}

class ImportSummary {
  const ImportSummary({required this.added, required this.duplicates, required this.failed, this.skipped = 0});
  final int added;
  final int duplicates;
  final int failed;
  final int skipped;
}

class ImportDecision {
  const ImportDecision({required this.name, this.categoryId});
  final String name;
  final String? categoryId;
}

class ImportCategoryOption {
  const ImportCategoryOption({required this.id, required this.name});
  final String id;
  final String name;
}

class DocumentRepository {
  DocumentRepository({AppDatabase? database})
      : _database = database ?? AppDatabase.instance;

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<List<DocumentRecord>> list({String query = '', bool favoritesOnly = false, bool recentOnly = false}) async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      '''
      SELECT d.*, c.name AS category_name,
        (SELECT GROUP_CONCAT(t.name, ', ') FROM document_tags dt
          INNER JOIN tags t ON t.id = dt.tag_id WHERE dt.document_id = d.id) AS tag_names
      FROM documents d
      LEFT JOIN categories c ON c.id = d.category_id
      WHERE d.deleted_at IS NULL
        AND (? = 0 OR d.last_opened_at IS NOT NULL)
        AND d.name LIKE ?
      ORDER BY d.last_opened_at DESC, d.name COLLATE NOCASE ASC
      ''',
      [recentOnly ? 1 : 0, '%${query.trim()}%'],
    );
    // Avoid SQLite JSON1 dependency: several Android SQLite builds do not
    // expose json_extract(). Favorite metadata is decoded in Dart instead.
    final documents = rows.map(DocumentRecord.fromMap).toList();
    return favoritesOnly
        ? documents.where((document) => document.isFavorite).toList()
        : documents;
  }

  Future<List<DocumentRecord>> listInFolder(String? folderId) async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      '''
      SELECT d.*, c.name AS category_name,
        (SELECT GROUP_CONCAT(t.name, ', ') FROM document_tags dt
          INNER JOIN tags t ON t.id = dt.tag_id WHERE dt.document_id = d.id) AS tag_names
      FROM documents d
      LEFT JOIN categories c ON c.id = d.category_id
      WHERE d.deleted_at IS NULL AND ${folderId == null ? 'd.folder_id IS NULL' : 'd.folder_id = ?'}
      ORDER BY d.name COLLATE NOCASE ASC
      ''',
      folderId == null ? [] : [folderId],
    );
    return rows.map(DocumentRecord.fromMap).toList();
  }

  Future<Directory> _privateFolderFor(String? folderId) async {
    final base = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(base.path, 'DocsGrid', 'PDFs'));
    await root.create(recursive: true);
    if (folderId == null) return root;

    final db = await _database.database;
    final segments = <String>[];
    String? currentId = folderId;
    final seen = <String>{};
    while (currentId != null) {
      if (!seen.add(currentId)) throw StateError('Folder hierarchy contains a cycle.');
      final rows = await db.query(
        'folders',
        columns: ['name', 'parent_id'],
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [currentId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Destination folder no longer exists.');
      segments.add(rows.first['name'] as String);
      currentId = rows.first['parent_id'] as String?;
    }
    var directory = root;
    for (final segment in segments.reversed) {
      directory = Directory(p.join(directory.path, segment));
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<void> moveToFolder(DocumentRecord document, String? folderId) async {
    if (document.folderId == folderId) return;
    final db = await _database.database;
    final storage = StorageLocationService.instance;

    String? destinationUri;
    if (folderId == null) {
      destinationUri = (await storage.selectedFolder())?['uri'];
    } else {
      final rows = await db.query(
        'folders',
        columns: ['storage_uri_or_relative_path'],
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [folderId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Destination folder no longer exists.');
      destinationUri = rows.first['storage_uri_or_relative_path'] as String?;
      destinationUri ??= await FolderRepository().ensurePhysicalStorageUri(folderId);
    }

    final sourceUri = document.storagePath;
    final sourceIsShared = sourceUri.startsWith('content://') || sourceUri.startsWith('file://');
    String newStorageUri = sourceUri;
    var copiedToNewLocation = false;

    if (destinationUri != null) {
      if (sourceIsShared) {
        newStorageUri = await storage.copyPdf(
          sourceUri: sourceUri,
          parentUri: destinationUri,
          name: '${document.name}.pdf',
        );
      } else {
        final source = File(sourceUri);
        if (!await source.exists()) throw StateError('Original PDF is missing; it was not moved.');
        newStorageUri = await storage.copyPdf(
          sourceUri: Uri.file(source.path).toString(),
          parentUri: destinationUri,
          name: '${document.name}.pdf',
        );
      }
      copiedToNewLocation = newStorageUri != sourceUri;
    } else {
      // With no external folder selected, preserve the same folder hierarchy
      // inside the app-private PDF library rather than changing metadata only.
      final targetDirectory = await _privateFolderFor(folderId);
      final target = await _uniqueFile(targetDirectory, '${document.name}.pdf');
      if (sourceIsShared) {
        try {
          await storage.copyPdfToPath(
            sourceUri: sourceUri,
            destinationPath: target.path,
          );
          final sourceDigest = await storage.sha256Pdf(sourceUri);
          final copiedDigest = (await sha256.bind(target.openRead()).first).toString();
          if (sourceDigest != copiedDigest) {
            throw StateError('PDF verification failed; original file was kept.');
          }
        } catch (_) {
          try { if (await target.exists()) await target.delete(); } catch (_) {}
          rethrow;
        }
      } else {
        final source = File(sourceUri);
        if (!await source.exists()) throw StateError('Original PDF is missing; it was not moved.');
        await source.copy(target.path);
        final sourceDigest = (await sha256.bind(source.openRead()).first).toString();
        final copiedDigest = (await sha256.bind(target.openRead()).first).toString();
        if (sourceDigest != copiedDigest) {
          await target.delete();
          throw StateError('PDF verification failed; original file was kept.');
        }
      }
      newStorageUri = target.path;
      copiedToNewLocation = newStorageUri != sourceUri;
    }

    String? relativePath;
    if (!newStorageUri.startsWith('content://') &&
        !newStorageUri.startsWith('file://')) {
      final base = await getApplicationDocumentsDirectory();
      final libraryRoot = p.join(base.path, 'DocsGrid', 'PDFs');
      relativePath = p.relative(newStorageUri, from: libraryRoot);
    }

    try {
      await db.transaction((txn) async {
        final count = await txn.update(
          'documents',
          {
            'folder_id': folderId,
            'storage_uri': newStorageUri,
            'relative_path': relativePath,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [document.id],
        );
        if (count == 0) throw StateError('PDF record no longer exists.');
        await _recordHistory(txn, document.id, 'moved_to_folder', {
          'folder_id': folderId,
          'storage_uri': newStorageUri,
        });
      });
    } catch (_) {
      if (copiedToNewLocation && newStorageUri != sourceUri) {
        try {
          if (newStorageUri.startsWith('content://') || newStorageUri.startsWith('file://')) {
            await storage.deletePdf(newStorageUri);
          } else {
            final target = File(newStorageUri);
            if (await target.exists()) await target.delete();
          }
        } catch (_) {
          // Keep the original; an orphaned verified copy is safer than data loss.
        }
      }
      rethrow;
    }

    if (copiedToNewLocation && newStorageUri != sourceUri) {
      try {
        if (sourceIsShared) {
          await storage.deletePdf(sourceUri);
        } else {
          final source = File(sourceUri);
          if (await source.exists()) await source.delete();
        }
      } catch (_) {
        throw StateError(
          'PDF was moved and verified, but the old copy could not be removed. '
          'The library now points to the new copy; check both locations before deleting either.',
        );
      }
    }
  }

  /// Moves the existing document library into the currently selected platform
  /// folder. Each file is copied and verified, its DB reference is committed,
  /// and only then is the old copy removed. Safe to retry after interruption.
  Future<int> migrateExistingLibraryToSelectedStorage({
    void Function(int completed, int total, String current)? onProgress,
  }) async {
    final storage = StorageLocationService.instance;
    final selected = await storage.selectedFolder();
    if (selected == null) {
      throw StateError('Choose a storage folder before starting migration.');
    }
    final rootUri = selected['uri']!;
    final db = await _database.database;
    final folderUris = <String, String>{};

    Future<void> mirrorFolders(String? parentId, String parentUri) async {
      final rows = await db.query(
        'folders',
        columns: ['id', 'name'],
        where: parentId == null
            ? 'parent_id IS NULL AND deleted_at IS NULL'
            : 'parent_id = ? AND deleted_at IS NULL',
        whereArgs: parentId == null ? null : [parentId],
        orderBy: 'name COLLATE NOCASE ASC',
      );
      for (final row in rows) {
        final id = row['id'] as String;
        final name = row['name'] as String;
        String childUri;
        try {
          childUri = await storage.findChildUri(parentUri: parentUri, name: name);
        } catch (_) {
          childUri = await storage.createDirectory(parentUri: parentUri, name: name);
        }
        folderUris[id] = childUri;
        await db.update(
          'folders',
          {
            'storage_uri_or_relative_path': childUri,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [id],
        );
        await mirrorFolders(id, childUri);
      }
    }

    await mirrorFolders(null, rootUri);

    final rows = await db.query(
      'documents',
      columns: ['id', 'name', 'storage_uri', 'folder_id', 'sha256'],
      orderBy: 'created_at ASC',
    );
    var migrated = 0;
    onProgress?.call(0, rows.length, 'Preparing migration');
    for (final row in rows) {
      final id = row['id'] as String;
      final name = row['name'] as String;
      final sourceUri = row['storage_uri'] as String?;
      if (sourceUri == null || sourceUri.isEmpty) {
        throw StateError('PDF "$name" has no saved storage location. Migration stopped without deleting it.');
      }
      final folderId = row['folder_id'] as String?;
      final parentUri = folderId == null ? rootUri : folderUris[folderId];
      if (parentUri == null) {
        throw StateError('Destination folder for "$name" could not be prepared. Migration can be retried safely.');
      }

      // Hash and copy through native file streams. This avoids loading large PDFs
      // into the Dart heap during migration on either platform.
      final sourceLocation = sourceUri.startsWith('content://') || sourceUri.startsWith('file://')
          ? sourceUri
          : Uri.file(sourceUri).toString();
      final sourceDigest = sourceUri.startsWith('content://') || sourceUri.startsWith('file://')
          ? await storage.sha256Pdf(sourceUri)
          : (await sha256.bind(File(sourceUri).openRead()).first).toString();

      String? destinationUri;
      var createdDestination = false;
      try {
        final existingUri = await storage.findChildUri(
          parentUri: parentUri,
          name: '$name.pdf',
        );
        if (await storage.sha256Pdf(existingUri) == sourceDigest) {
          destinationUri = existingUri;
        }
      } catch (_) {
        // No verified matching file in the destination; create a new copy below.
      }

      if (destinationUri == null) {
        destinationUri = await storage.copyPdf(
          sourceUri: sourceLocation,
          parentUri: parentUri,
          name: '$name.pdf',
        );
        createdDestination = true;
      }

      try {
        await db.transaction((txn) async {
          final count = await txn.update(
            'documents',
            {
              'storage_uri': destinationUri,
              'relative_path': null,
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            },
            where: 'id = ?',
            whereArgs: [id],
          );
          if (count == 0) throw StateError('PDF record "$name" disappeared during migration.');
          await _recordHistory(txn, id, 'storage_migrated', {
            'from': sourceUri,
            'to': destinationUri,
          });
        });
      } catch (_) {
        if (createdDestination && destinationUri != sourceUri) {
          try { await storage.deletePdf(destinationUri); } catch (_) {}
        }
        rethrow;
      }

      if (destinationUri != sourceUri) {
        try {
          if (sourceUri.startsWith('content://') ||
              (Platform.isIOS && sourceUri.startsWith('file://'))) {
            await storage.deletePdf(sourceUri);
          } else {
            final oldPath = sourceUri.startsWith('file://')
                ? Uri.parse(sourceUri).toFilePath()
                : sourceUri;
            final oldFile = File(oldPath);
            if (await oldFile.exists()) await oldFile.delete();
          }
        } catch (_) {
          throw StateError(
            '"$name.pdf" was copied and verified and the library now points to the new copy, '
            'but the old copy could not be removed. Both copies were retained.',
          );
        }
      }
      migrated++;
      onProgress?.call(migrated, rows.length, '$name.pdf');
    }
    return migrated;
  }

  /// Reconnects a missing or inaccessible PDF to a user-selected copy.
  /// If the record has a SHA-256 value, the replacement must match exactly.
  Future<void> relinkDocument(DocumentRecord document) async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (picked.isEmpty) return;
    final pickedFile = picked.single;
    final sourcePath = pickedFile.path;
    if (sourcePath == null || sourcePath.isEmpty) {
      throw StateError('The selected PDF provider did not expose a readable file path. Save the PDF to device storage and select it again.');
    }

    final source = File(sourcePath);
    if (!await source.exists()) throw StateError('The selected PDF is no longer available.');
    final header = await source.openRead(0, 5).fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    if (header.length < 5 || String.fromCharCodes(header) != '%PDF-') {
      throw StateError('The selected file is not a valid PDF.');
    }
    final digest = (await sha256.bind(source.openRead()).first).toString();
    final size = await source.length();

    final db = await _database.database;
    final rows = await db.query(
      'documents',
      columns: ['sha256', 'folder_id'],
      where: 'id = ?',
      whereArgs: [document.id],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('PDF record no longer exists.');
    final expected = rows.first['sha256'] as String?;
    if (expected != null && expected.isNotEmpty && expected != digest) {
      throw StateError('This PDF does not match the original document (SHA-256 mismatch).');
    }

    final storage = StorageLocationService.instance;
    final folderId = rows.first['folder_id'] as String?;
    String? destinationUri;
    if (folderId == null) {
      destinationUri = (await storage.selectedFolder())?['uri'];
    } else {
      final folderRows = await db.query(
        'folders',
        columns: ['storage_uri_or_relative_path'],
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [folderId],
        limit: 1,
      );
      destinationUri = folderRows.isEmpty
          ? null
          : folderRows.first['storage_uri_or_relative_path'] as String?;
      destinationUri ??= await FolderRepository().ensurePhysicalStorageUri(folderId);
    }

    late final String newUri;
    String? relativePath;
    if (destinationUri != null) {
      newUri = await storage.copyPdf(
        sourceUri: Uri.file(source.path).toString(),
        parentUri: destinationUri,
        name: '${document.name}.pdf',
      );
      final copiedDigest = await storage.sha256Pdf(newUri);
      if (copiedDigest != digest) {
        try { await storage.deletePdf(newUri); } catch (_) {}
        throw StateError('Replacement PDF verification failed; the existing document reference was not changed.');
      }
    } else {
      final library = await _privateFolderFor(folderId);
      final target = await _uniqueFile(library, '${document.name}.pdf');
      await source.copy(target.path);
      final copiedDigest = (await sha256.bind(target.openRead()).first).toString();
      if (copiedDigest != digest) {
        try { await target.delete(); } catch (_) {}
        throw StateError('Replacement PDF verification failed; the existing document reference was not changed.');
      }
      newUri = target.path;
      relativePath = p.relative(target.path, from: p.join(
        (await getApplicationDocumentsDirectory()).path, 'DocsGrid', 'PDFs',
      ));
    }

    try {
      await db.transaction((txn) async {
        final count = await txn.update(
          'documents',
          {
            'storage_uri': newUri,
            'relative_path': relativePath,
            'size_bytes': size,
            'sha256': digest,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [document.id],
        );
        if (count == 0) throw StateError('PDF record no longer exists.');
        await _recordHistory(txn, document.id, 'relinked', {
          'source_name': pickedFile.name,
          'storage_uri': newUri,
        });
      });
    } catch (_) {
      try {
        if (newUri.startsWith('content://') || newUri.startsWith('file://')) {
          await storage.deletePdf(newUri);
        } else {
          final file = File(newUri);
          if (await file.exists()) await file.delete();
        }
      } catch (_) {}
      rethrow;
    }
  }


  Future<ImportSummary> importScannedPdf(File source, {String? displayName, String? targetFolderUri, String? targetFolderId, String sourceType = 'scanner'}) async {
    if (!await source.exists()) throw StateError('Scanned PDF is not available.');
    final header = await source.openRead(0, 5).fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    if (header.length < 5 || String.fromCharCodes(header) != '%PDF-') {
      throw StateError('Scanner output is not a valid PDF.');
    }
    final digest = (await sha256.bind(source.openRead()).first).toString();
    final db = await _database.database;
    final duplicate = await db.query('documents',
      columns: ['id'], where: 'sha256 = ? AND deleted_at IS NULL',
      whereArgs: [digest], limit: 1);
    if (duplicate.isNotEmpty) return const ImportSummary(added: 0, duplicates: 1, failed: 0);

    final storage = StorageLocationService.instance;
    final selected = await storage.selectedFolder();
    final requestedName = displayName?.trim();
    final safeName = _safePdfName(requestedName == null || requestedName.isEmpty
        ? p.basename(source.path)
        : (requestedName.toLowerCase().endsWith('.pdf') ? requestedName : '$requestedName.pdf'));
    final id = _uuid.v4();
    late final String uri;
    String? relativePath;
    final folderUri = targetFolderId == null
        ? null
        : await FolderRepository().ensurePhysicalStorageUri(targetFolderId);
    final destinationUri = targetFolderUri ?? folderUri ?? selected?['uri'];
    if (destinationUri != null) {
      uri = await storage.copyPdf(
        sourceUri: Uri.file(source.path).toString(),
        parentUri: destinationUri,
        name: safeName,
      );
    } else {
      final base = await getApplicationDocumentsDirectory();
      final library = Directory(p.join(base.path, 'DocsGrid', 'PDFs'));
      await library.create(recursive: true);
      final target = await _uniqueFile(library, safeName);
      await source.copy(target.path);
      final copiedDigest = (await sha256.bind(target.openRead()).first).toString();
      if (copiedDigest != digest) {
        await target.delete();
        throw StateError('Scanned PDF verification failed.');
      }
      uri = target.path;
      relativePath = p.relative(target.path, from: library.path);
    }

    final now = DateTime.now().toUtc().toIso8601String();
    try {
      await db.transaction((txn) async {
        await txn.insert('documents', {
          'id': id,
          'name': p.basenameWithoutExtension(safeName),
          'original_name': safeName,
          'storage_uri': uri,
          'relative_path': relativePath,
          'mime_type': 'application/pdf',
          'size_bytes': await source.length(),
          'sha256': digest,
          'folder_id': targetFolderId,
          'extracted_text_status': 'pending',
          'created_at': now,
          'updated_at': now,
          'metadata_json': '{}',
          'source': sourceType,
        });
        await _recordHistory(txn, id, sourceType == 'share' ? 'imported_from_share' : 'scanned', {'name': safeName, 'folder_id': targetFolderId});
      });
    } catch (_) {
      try {
        if (uri.startsWith('content://') || uri.startsWith('file://')) {
          await storage.deletePdf(uri);
        } else {
          final file = File(uri);
          if (await file.exists()) await file.delete();
        }
      } catch (_) {}
      rethrow;
    }
    return const ImportSummary(added: 1, duplicates: 0, failed: 0);
  }

  Future<ImportSummary> importPdfs({
    Future<ImportDecision?> Function(String suggestedName, String? suggestedCategoryId, List<ImportCategoryOption> categories)? review,
    String? targetFolderId,
  }) async {
    final pickedFiles = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (pickedFiles.isEmpty) {
      return const ImportSummary(added: 0, duplicates: 0, failed: 0);
    }

    final storage = StorageLocationService.instance;
    final selectedFolder = await storage.selectedFolder();
    final destinationFolderUri = selectedFolder == null
        ? null
        : targetFolderId == null
            ? selectedFolder['uri']
            : await FolderRepository().ensurePhysicalStorageUri(targetFolderId);
    final library = selectedFolder == null ? await _privateFolderFor(targetFolderId) : null;
    final db = await _database.database;
    var added = 0;
    var duplicates = 0;
    var failed = 0;
    var skipped = 0;
    final categoryRows = await db.query('categories', columns: ['id', 'name'], orderBy: 'name COLLATE NOCASE');
    final categoryOptions = categoryRows.map((row) => ImportCategoryOption(
      id: row['id'] as String,
      name: row['name'] as String,
    )).toList(growable: false);

    for (final picked in pickedFiles) {
      String? createdUri;
      try {
        final sourcePath = picked.path;
        final sourceFile = sourcePath == null ? null : File(sourcePath);
        final fallbackBytes = sourceFile == null ? await picked.readAsBytes() : null;
        if (sourceFile != null && !await sourceFile.exists()) {
          throw StateError('The selected PDF is no longer accessible.');
        }
        final header = sourceFile != null
            ? await sourceFile.openRead(0, 5).fold<List<int>>(<int>[], (a, b) => a..addAll(b))
            : fallbackBytes!.take(5).toList();
        if (header.length < 5 || String.fromCharCodes(header) != '%PDF-') {
          failed++;
          continue;
        }
        final digest = sourceFile != null
            ? (await sha256.bind(sourceFile.openRead()).first).toString()
            : sha256.convert(fallbackBytes!).toString();
        final sizeBytes = sourceFile != null
            ? await sourceFile.length()
            : fallbackBytes!.length;
        final existing = await db.query(
          'documents',
          columns: ['id'],
          where: 'sha256 = ? AND deleted_at IS NULL',
          whereArgs: [digest],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          duplicates++;
          continue;
        }

        final suggestedName = p.basenameWithoutExtension(picked.name);
        final suggestedCategoryId = _suggestCategoryId(picked.name, categoryOptions);
        final decision = review == null
            ? ImportDecision(name: suggestedName, categoryId: suggestedCategoryId)
            : await review(suggestedName, suggestedCategoryId, categoryOptions);
        if (decision == null) {
          skipped++;
          continue;
        }
        final safeName = _safePdfName(decision.name);
        final selectedCategoryId = categoryOptions.any((item) => item.id == decision.categoryId)
            ? decision.categoryId
            : null;
        late final String storedName;
        late final String? relativePath;
        if (destinationFolderUri != null) {
          createdUri = sourceFile != null
              ? await storage.copyPdf(
                  sourceUri: Uri.file(sourceFile.path).toString(),
                  parentUri: destinationFolderUri,
                  name: safeName,
                )
              : await storage.savePdf(
                  treeUri: destinationFolderUri,
                  name: safeName,
                  bytes: fallbackBytes!,
                );
          final copiedDigest = await storage.sha256Pdf(createdUri);
          if (copiedDigest != digest) {
            throw StateError('Imported PDF failed SHA-256 verification in selected storage.');
          }
          storedName = p.basenameWithoutExtension(safeName);
          relativePath = null;
        } else {
          final target = await _uniqueFile(library!, safeName);
          if (sourceFile != null) {
            await sourceFile.copy(target.path);
          } else {
            await target.writeAsBytes(fallbackBytes!, flush: true);
          }
          final copiedDigest = (await sha256.bind(target.openRead()).first).toString();
          if (copiedDigest != digest) {
            await target.delete();
            throw StateError('Imported PDF verification failed.');
          }
          createdUri = target.path;
          storedName = p.basenameWithoutExtension(target.path);
          relativePath = p.relative(target.path, from: library.path);
        }

        final now = DateTime.now().toUtc().toIso8601String();
        final documentId = _uuid.v4();
        await db.transaction((txn) async {
          await txn.insert('documents', {
            'id': documentId,
            'name': storedName,
            'original_name': picked.name,
            'storage_uri': createdUri,
            'relative_path': relativePath,
            'mime_type': 'application/pdf',
            'size_bytes': sizeBytes,
            'sha256': digest,
            'category_id': selectedCategoryId,
            'folder_id': targetFolderId,
            'extracted_text_status': 'pending',
            'created_at': now,
            'updated_at': now,
            'metadata_json': '{}',
            'source': 'file_picker',
          });
          await _recordHistory(txn, documentId, 'imported', {'name': storedName});
        });
        added++;
      } catch (_) {
        if (createdUri != null) {
          try {
            if (createdUri.startsWith('content://') || createdUri.startsWith('file://')) {
              await storage.deletePdf(createdUri);
            } else {
              final orphan = File(createdUri);
              if (await orphan.exists()) await orphan.delete();
            }
          } catch (_) {}
        }
        failed++;
      }
    }
    return ImportSummary(added: added, duplicates: duplicates, failed: failed, skipped: skipped);
  }

  String? _suggestCategoryId(String fileName, List<ImportCategoryOption> categories) {
    final value = fileName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
    const rules = <String, List<String>>{
      'identity': ['aadhaar', 'aadhar', 'pan card', 'passport', 'voter', 'driving licence', 'driving license'],
      'insurance': ['policy', 'insurance', 'claim', 'premium', 'renewal'],
      'finance': ['bank', 'statement', 'invoice', 'receipt', 'upi', 'loan', 'tax', 'itr'],
      'medical': ['medical', 'health', 'prescription', 'doctor', 'lab report', 'blood test'],
      'property': ['property', 'house', 'land', 'rent', 'registry', 'sale deed'],
      'vehicle': ['vehicle', 'car', 'bike', 'motor', 'registration', 'rc book', 'chassis'],
      'education': ['education', 'school', 'college', 'marksheet', 'degree', 'certificate'],
    };
    for (final category in categories) {
      final keywords = rules[category.name.toLowerCase()];
      if (keywords != null && keywords.any((word) => value.contains(word))) return category.id;
    }
    return null;
  }

  String _safePdfName(String name) {
    var cleaned = p.basename(name).replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
    if (cleaned.isEmpty) cleaned = 'Document.pdf';
    if (!cleaned.toLowerCase().endsWith('.pdf')) cleaned = '$cleaned.pdf';
    return cleaned;
  }

  Future<File> _uniqueFile(Directory directory, String name) async {
    var candidate = File(p.join(directory.path, name));
    var counter = 1;
    while (await candidate.exists()) {
      final stem = p.basenameWithoutExtension(name);
      candidate = File(p.join(directory.path, '$stem ($counter).pdf'));
      counter++;
    }
    return candidate;
  }

  /// Soft-delete a group of PDFs atomically; the physical files remain recoverable.
  Future<void> moveManyToTrash(List<DocumentRecord> documents) async {
    if (documents.isEmpty) return;
    final db = await _database.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      for (final document in documents) {
        final changed = await txn.update(
          'documents',
          {'deleted_at': now, 'updated_at': now},
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [document.id],
        );
        if (changed > 0) {
          await _recordHistory(txn, document.id, 'moved_to_recycle_bin', {'bulk': true});
        }
      }
    });
  }

  /// Move several PDFs using the same verified copy/commit/cleanup path as a single move.
  Future<Map<String, Object>> moveManyToFolder(List<DocumentRecord> documents, String? folderId) async {
    var moved = 0;
    final failures = <String>[];
    for (final document in documents) {
      try {
        await moveToFolder(document, folderId);
        moved++;
      } catch (error) {
        failures.add('${document.name}: $error');
      }
    }
    return {'moved': moved, 'failures': failures};
  }
  Future<void> setFavorite(DocumentRecord document, bool favorite) async {
    final db = await _database.database;
    final rows = await db.query(
      'documents',
      columns: ['metadata_json'],
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [document.id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final metadata = jsonDecode((rows.first['metadata_json'] as String?) ?? '{}')
        as Map<String, dynamic>;
    metadata['favorite'] = favorite;
    await db.update(
      'documents',
      {
        'metadata_json': jsonEncode(metadata),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [document.id],
    );
    await _recordHistory(db, document.id, favorite ? 'favorited' : 'unfavorited', {});
  }

  Future<void> markOpened(DocumentRecord document) async {
    final db = await _database.database;
    await db.update('documents', {
      'last_opened_at': DateTime.now().toUtc().toIso8601String(),
    }, where: 'id = ?', whereArgs: [document.id]);
    await _recordHistory(db, document.id, 'opened', {});
  }

  Future<List<DocumentRecord>> listTrash({String query = ''}) async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      '''
      SELECT d.*, c.name AS category_name
      FROM documents d
      LEFT JOIN categories c ON c.id = d.category_id
      WHERE d.deleted_at IS NOT NULL AND d.name LIKE ?
      ORDER BY d.deleted_at DESC
      ''',
      ['%${query.trim()}%'],
    );
    return rows.map(DocumentRecord.fromMap).toList();
  }

  Future<void> restoreFromTrash(DocumentRecord document) async {
    final db = await _database.database;
    await db.update('documents', {
      'deleted_at': null,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, where: 'id = ? AND deleted_at IS NOT NULL', whereArgs: [document.id]);
    await _recordHistory(db, document.id, 'restored', {});
  }

  Future<void> moveToTrash(DocumentRecord document) async {
    final db = await _database.database;
    await db.update('documents', {
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, where: 'id = ?', whereArgs: [document.id]);
    await _recordHistory(db, document.id, 'moved_to_recycle_bin', {});
  }

  Future<void> rename(DocumentRecord document, String newName) async {
    final cleaned = newName.trim();
    if (cleaned.isEmpty) throw ArgumentError('Name cannot be empty.');
    final safeBase = p.basenameWithoutExtension(cleaned)
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .trim();
    if (safeBase.isEmpty) throw ArgumentError('Name is not valid.');
    final safeName = '$safeBase.pdf';
    final isShared = document.storagePath.startsWith('content://') ||
        document.storagePath.startsWith('file://');
    late final String newStorageUri;

    if (isShared) {
      newStorageUri = await StorageLocationService.instance.renamePdf(
        uri: document.storagePath,
        name: safeName,
      );
    } else {
      final oldFile = File(document.storagePath);
      if (!await oldFile.exists()) {
        throw StateError('Original PDF is missing. The database name was not changed.');
      }
      final newFile = File(p.join(oldFile.parent.path, safeName));
      if (await newFile.exists() && newFile.path != oldFile.path) {
        throw StateError('A file with this name already exists.');
      }
      await oldFile.rename(newFile.path);
      newStorageUri = newFile.path;
    }

    final db = await _database.database;
    try {
      await db.transaction((txn) async {
        final now = DateTime.now().toUtc().toIso8601String();
        final count = await txn.update(
          'documents',
          {
            'name': safeBase,
            'storage_uri': newStorageUri,
            'relative_path': null,
            'updated_at': now,
          },
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [document.id],
        );
        if (count == 0) throw StateError('PDF record no longer exists.');
        await _recordHistory(txn, document.id, 'renamed', {
          'from': document.name,
          'to': safeBase,
        });
      });
    } catch (_) {
      try {
        if (isShared) {
          await StorageLocationService.instance.renamePdf(
            uri: newStorageUri,
            name: '${document.name}.pdf',
          );
        } else {
          final renamedFile = File(newStorageUri);
          final oldFile = File(document.storagePath);
          if (await renamedFile.exists()) await renamedFile.rename(oldFile.path);
        }
      } catch (_) {
        // Keep both the original DB reference and the recovery copy if rollback fails.
      }
      rethrow;
    }
  }

  Future<void> permanentlyDelete(DocumentRecord document) async {
    if (document.storagePath.startsWith('content://') ||
        document.storagePath.startsWith('file://')) {
      await StorageLocationService.instance.deletePdf(document.storagePath);
    } else {
      final file = File(document.storagePath);
      if (await file.exists()) await file.delete();
    }
    final db = await _database.database;
    await _recordHistory(db, null, 'permanently_deleted', {'document_id': document.id, 'name': document.name});
    await db.delete('documents', where: 'id = ?', whereArgs: [document.id]);
  }

  Future<void> _recordHistory(
    DatabaseExecutor db,
    String? documentId,
    String action,
    Map<String, Object?> details,
  ) async {
    await db.insert('history', {
      'id': _uuid.v4(),
      'document_id': documentId,
      'action': action,
      'details_json': jsonEncode(details),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }
}
