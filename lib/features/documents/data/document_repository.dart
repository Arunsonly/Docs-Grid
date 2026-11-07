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
  const ImportSummary({required this.added, required this.duplicates, required this.failed});
  final int added;
  final int duplicates;
  final int failed;
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
        AND (? = 0 OR COALESCE(json_extract(d.metadata_json, '\$.favorite'), 0) = 1)
        AND (? = 0 OR d.last_opened_at IS NOT NULL)
        AND d.name LIKE ?
      ORDER BY d.last_opened_at DESC, d.name COLLATE NOCASE ASC
      ''',
      [favoritesOnly ? 1 : 0, recentOnly ? 1 : 0, '%${query.trim()}%'],
    );
    return rows.map(DocumentRecord.fromMap).toList();
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

  Future<void> moveToFolder(DocumentRecord document, String? folderId) async {
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
    }

    final sourceIsShared = document.storagePath.startsWith('content://') || document.storagePath.startsWith('file://');
    String newStorageUri = document.storagePath;
    var copiedToNewLocation = false;

    // Copy first, verify bytes, and keep the original until SQLite commits.
    if (destinationUri != null && sourceIsShared) {
      newStorageUri = await storage.copyPdf(
        sourceUri: document.storagePath,
        parentUri: destinationUri,
        name: '${document.name}.pdf',
      );
      copiedToNewLocation = true;
    } else if (destinationUri != null && !sourceIsShared) {
      final source = File(document.storagePath);
      if (!await source.exists()) {
        throw StateError('Original PDF is missing; it was not moved.');
      }
      final bytes = await source.readAsBytes();
      newStorageUri = await storage.savePdf(
        treeUri: destinationUri,
        name: '${document.name}.pdf',
        bytes: bytes,
      );
      copiedToNewLocation = true;
    } else if (sourceIsShared) {
      // Moving from Android SAF back to app-private storage is supported by
      // reading the provider stream, verifying the local copy, then updating
      // the database before removing the provider document.
      final base = await getApplicationDocumentsDirectory();
      final library = Directory(p.join(base.path, 'DocsGrid', 'PDFs'));
      await library.create(recursive: true);
      final bytes = await storage.readPdf(document.storagePath);
      final target = await _uniqueFile(library, '${document.name}.pdf');
      await target.writeAsBytes(bytes, flush: true);
      final sourceDigest = sha256.convert(bytes).toString();
      final savedDigest = sha256.convert(await target.readAsBytes()).toString();
      if (sourceDigest != savedDigest) {
        await target.delete();
        throw StateError('PDF verification failed; original file was kept.');
      }
      newStorageUri = target.path;
      copiedToNewLocation = true;
    }

    try {
      await db.transaction((txn) async {
        final count = await txn.update(
          'documents',
          {
            'folder_id': folderId,
            'storage_uri': newStorageUri,
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
      if (copiedToNewLocation && newStorageUri != document.storagePath) {
        try {
          if (newStorageUri.startsWith('content://') || newStorageUri.startsWith('file://')) {
            await storage.deletePdf(newStorageUri);
          } else {
            final target = File(newStorageUri);
            if (await target.exists()) await target.delete();
          }
        } catch (_) {
          // Preserve the original even if cleanup of the unreferenced copy fails.
        }
      }
      rethrow;
    }

    if (copiedToNewLocation && newStorageUri != document.storagePath) {
      try {
        if (sourceIsShared) {
          await storage.deletePdf(document.storagePath);
        } else {
          final source = File(document.storagePath);
          if (await source.exists()) await source.delete();
        }
      } catch (_) {
        throw StateError(
          'PDF was moved and verified, but the old copy could not be removed. '
          'Your data is safe; check both locations before deleting either copy.',
        );
      }
    }
  }

  /// Moves the existing document library into the currently selected platform
  /// folder. Each file is copied and verified, its DB reference is committed,
  /// and only then is the old copy removed. Safe to retry after interruption.
  Future<int> migrateExistingLibraryToSelectedStorage() async {
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

      final sourceIsShared = sourceUri.startsWith('content://') || sourceUri.startsWith('file://');
      final sourceBytes = sourceIsShared
          ? await storage.readPdf(sourceUri)
          : await File(sourceUri).readAsBytes();
      final sourceDigest = sha256.convert(sourceBytes).toString();

      String? destinationUri;
      try {
        final existingUri = await storage.findChildUri(
          parentUri: parentUri,
          name: '$name.pdf',
        );
        final existingBytes = await storage.readPdf(existingUri);
        if (sha256.convert(existingBytes).toString() == sourceDigest) {
          destinationUri = existingUri;
        }
      } catch (_) {
        // No matching file in the destination; a new verified copy is made below.
      }

      destinationUri ??= sourceIsShared
          ? await storage.copyPdf(
              sourceUri: sourceUri,
              parentUri: parentUri,
              name: '$name.pdf',
            )
          : await storage.savePdf(
              treeUri: parentUri,
              name: '$name.pdf',
              bytes: sourceBytes,
            );

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
        if (destinationUri != sourceUri) {
          try { await storage.deletePdf(destinationUri); } catch (_) {}
        }
        rethrow;
      }

      if (destinationUri != sourceUri) {
        try {
          if (sourceIsShared) {
            await storage.deletePdf(sourceUri);
          } else {
            final oldFile = File(sourceUri);
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
    }
    return migrated;
  }

  Future<ImportSummary> importPdfs() async {
    final pickedFiles = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (pickedFiles.isEmpty) {
      return const ImportSummary(added: 0, duplicates: 0, failed: 0);
    }

    final storage = StorageLocationService.instance;
    final selectedFolder = await storage.selectedFolder();
    Directory? library;
    if (selectedFolder == null) {
      final base = await getApplicationDocumentsDirectory();
      library = Directory(p.join(base.path, 'DocsGrid', 'PDFs'));
      await library.create(recursive: true);
    }
    final db = await _database.database;
    var added = 0;
    var duplicates = 0;
    var failed = 0;

    for (final picked in pickedFiles) {
      try {
        final bytes = await picked.readAsBytes();
        if (bytes.length < 5 || String.fromCharCodes(bytes.take(5)) != '%PDF-') {
          failed++;
          continue;
        }
        final digest = sha256.convert(bytes).toString();
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
        final safeName = _safePdfName(picked.name);
        late final String storageUri;
        late final String storedName;
        late final String? relativePath;
        if (selectedFolder != null) {
          storageUri = await storage.savePdf(
            treeUri: selectedFolder['uri']!,
            name: safeName,
            bytes: bytes,
          );
          storedName = p.basenameWithoutExtension(safeName);
          relativePath = null;
        } else {
          final target = await _uniqueFile(library!, safeName);
          await target.writeAsBytes(bytes, flush: true);
          storageUri = target.path;
          storedName = p.basenameWithoutExtension(target.path);
          relativePath = p.relative(target.path, from: library.path);
        }
        final now = DateTime.now().toUtc().toIso8601String();
        final documentId = _uuid.v4();
        await db.insert('documents', {
          'id': documentId,
          'name': storedName,
          'original_name': picked.name,
          'storage_uri': storageUri,
          'relative_path': relativePath,
          'mime_type': 'application/pdf',
          'size_bytes': bytes.length,
          'sha256': digest,
          'extracted_text_status': 'pending',
          'created_at': now,
          'updated_at': now,
          'metadata_json': '{}',
          'source': 'file_picker',
        });
        await _recordHistory(db, documentId, 'imported', {'name': storedName});
        added++;
      } catch (_) {
        failed++;
      }
    }
    return ImportSummary(added: added, duplicates: duplicates, failed: failed);
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
    final safeBase = p.basenameWithoutExtension(cleaned).replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final safeName = '$safeBase.pdf';
    late final String newStorageUri;
    if (document.storagePath.startsWith('content://') || document.storagePath.startsWith('file://')) {
      newStorageUri = await StorageLocationService.instance.renamePdf(
        uri: document.storagePath,
        name: safeName,
      );
    } else {
      final oldFile = File(document.storagePath);
      final newFile = File(p.join(oldFile.parent.path, safeName));
      if (await newFile.exists() && newFile.path != oldFile.path) {
        throw StateError('A file with this name already exists.');
      }
      if (await oldFile.exists()) await oldFile.rename(newFile.path);
      newStorageUri = newFile.path;
    }
    final db = await _database.database;
    await db.update('documents', {
      'name': safeBase,
      'storage_uri': newStorageUri,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, where: 'id = ?', whereArgs: [document.id]);
    await _recordHistory(db, document.id, 'renamed', {'from': document.name, 'to': safeBase});
  }

  Future<void> permanentlyDelete(DocumentRecord document) async {
    if (document.storagePath.startsWith('content://')) {
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
