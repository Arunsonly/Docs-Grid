import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/storage/byte_stream_file.dart';
import '../../../core/storage/storage_location_service.dart';
import '../../../core/storage/portable_snapshot_events.dart';
import '../../../core/storage/storage_migration_gate.dart';
import '../../folders/data/folder_repository.dart';
import '../../reminders/data/reminder_notifications.dart';

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
    this.lastOpenedAt,
    this.source,
    this.sha256,
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
  final DateTime? lastOpenedAt;
  final String? source;
  final String? sha256;

  factory DocumentRecord.fromMap(Map<String, Object?> row) {
    Map<String, dynamic> metadata = <String, dynamic>{};
    try {
      final rawMetadata = row['metadata_json'];
      final decoded = rawMetadata is String && rawMetadata.isNotEmpty
          ? jsonDecode(rawMetadata)
          : <String, dynamic>{};
      if (decoded is Map<String, dynamic>) metadata = decoded;
    } catch (_) {
      // Damaged optional metadata must not make an otherwise valid PDF
      // unreadable. Non-critical flags safely fall back to their defaults.
    }
    return DocumentRecord(
      id: row['id'] as String,
      name: row['name'] as String,
      storagePath: (row['storage_uri'] as String?) ?? '',
      sizeBytes: (row['size_bytes'] as int?) ?? 0,
      createdAt: DateTime.parse(row['created_at'] as String),
      isFavorite: row['is_favorite'] == null
          ? metadata['favorite'] == true
          : row['is_favorite'] == 1,
      categoryId: row['category_id'] as String?,
      categoryName: row['category_name'] as String?,
      tagNames: ((row['tag_names'] as String?) ?? '').isEmpty
          ? const []
          : (row['tag_names'] as String).split(', '),
      folderId: row['folder_id'] as String?,
      lastOpenedAt: row['last_opened_at'] is String
          ? DateTime.tryParse(row['last_opened_at'] as String)
          : null,
      source: row['source'] as String?,
      sha256: row['sha256'] as String?,
    );
  }
}

class DocumentLibrarySummary {
  const DocumentLibrarySummary({
    required this.documentCount,
    required this.favoriteCount,
    required this.totalBytes,
  });

  final int documentCount;
  final int favoriteCount;
  final int totalBytes;
}

class DocumentPageCursor {
  const DocumentPageCursor({
    required this.lastOpenedAt,
    required this.name,
    required this.id,
  });

  final String lastOpenedAt;
  final String name;
  final String id;
}

class DocumentPage {
  const DocumentPage({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<DocumentRecord> items;
  final DocumentPageCursor? nextCursor;
  final bool hasMore;
}

class ImportSummary {
  const ImportSummary({required this.added, required this.duplicates, required this.failed, this.skipped = 0, this.errors = const []});
  final int added;
  final int duplicates;
  final int failed;
  final int skipped;
  final List<String> errors;
}

class ImportDecision {
  const ImportDecision({required this.name, this.categoryId, this.targetFolderId});
  final String name;
  final String? categoryId;
  final String? targetFolderId;
}

class ImportCategoryOption {
  const ImportCategoryOption({required this.id, required this.name});
  final String id;
  final String name;
}

class _DuplicatePdfException implements Exception {}

String escapeLikeWildcards(String value) {
  return value
      .replaceAll('\\', '\\\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');
}

class PdfImportDestination {
  const PdfImportDestination(this.uri, {required this.isAndroid});

  final String? uri;
  final bool isAndroid;

  bool get usesPrivateStorage => uri == null && !isAndroid;
  bool get requiresStorageSetup => uri == null && isAndroid;
}

/// Resolves the physical destination for a PDF import.
///
/// Android uses a shared portable or explicitly selected folder. If neither
/// is available, setup is required rather than silently creating a second
/// app-private DocsGrid library. Non-Android platforms may use private storage.
PdfImportDestination resolvePdfImportDestination({
  required bool isAndroid,
  String? portableDocumentsUri,
  String? selectedFolderUri,
  String? targetFolderUri,
}) {
  final rootUri = isAndroid
      ? (portableDocumentsUri ?? selectedFolderUri)
      : selectedFolderUri;
  return PdfImportDestination(targetFolderUri ?? rootUri, isAndroid: isAndroid);
}

class DocumentRepository {
  DocumentRepository({AppDatabase? database})
      : _database = database ?? AppDatabase.instance;

  final AppDatabase _database;
  static const _uuid = Uuid();
  DocumentLibrarySummary? _summaryCache;
  int? _summaryCacheRevision;

  /// Returns compact dashboard metrics without materializing document rows.
  Future<DocumentLibrarySummary> dashboardSummary() async {
    final db = await _database.database;
    final revisionRows = await db.query(
      'document_summary_state',
      columns: ['revision'],
      where: 'id = ?',
      whereArgs: [1],
      limit: 1,
    );
    final revision = revisionRows.isEmpty ? -1 : revisionRows.single['revision'] as int;
    final cached = _summaryCache;
    if (cached != null && _summaryCacheRevision == revision) return cached;
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS document_count,
             COALESCE(SUM(size_bytes), 0) AS total_bytes,
             COALESCE(SUM(CASE WHEN is_favorite = 1 THEN 1 ELSE 0 END), 0) AS favorite_count
      FROM documents
      WHERE deleted_at IS NULL
    ''');
    final row = rows.single;
    final summary = DocumentLibrarySummary(
      documentCount: (row['document_count'] as int?) ?? 0,
      favoriteCount: (row['favorite_count'] as int?) ?? 0,
      totalBytes: (row['total_bytes'] as int?) ?? 0,
    );
    _summaryCache = summary;
    _summaryCacheRevision = revision;
    return summary;
  }

  /// Returns the latest document activity: opened PDFs use last_opened_at;
  /// never-opened PDFs use created_at so recently added files also appear.
  Future<List<DocumentRecord>> recentActivity({int limit = 20}) async {
    if (limit < 1 || limit > 100) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 100.');
    }
    final db = await _database.database;
    final rows = await db.rawQuery('''
      SELECT d.*, c.name AS category_name,
        (SELECT GROUP_CONCAT(t.name, ', ') FROM document_tags dt
          INNER JOIN tags t ON t.id = dt.tag_id WHERE dt.document_id = d.id) AS tag_names
      FROM documents d
      LEFT JOIN categories c ON c.id = d.category_id
      WHERE d.deleted_at IS NULL
      ORDER BY COALESCE(d.last_opened_at, d.created_at) DESC,
               d.name COLLATE NOCASE ASC, d.id ASC
      LIMIT ?
    ''', [limit]);
    return rows.map(DocumentRecord.fromMap).toList(growable: false);
  }

  /// Fetches a bounded keyset page in the same order as the library screen.
  /// The cursor includes a unique id tie-breaker so equal names/timestamps
  /// cannot cause a row to repeat or disappear between pages.
  Future<DocumentPage> listPage({
    String query = '',
    bool favoritesOnly = false,
    bool recentOnly = false,
    int pageSize = 40,
    DocumentPageCursor? cursor,
  }) async {
    if (pageSize < 1 || pageSize > 100) {
      throw ArgumentError.value(pageSize, 'pageSize', 'Must be between 1 and 100.');
    }
    final db = await _database.database;
    final where = <String>['d.deleted_at IS NULL'];
    final args = <Object?>[];
    if (recentOnly) where.add('d.last_opened_at IS NOT NULL');
    if (favoritesOnly) where.add('d.is_favorite = 1');
    final normalizedQuery = query.trim();
    if (normalizedQuery.isNotEmpty) {
      // Search metadata and folder labels alongside filenames. The tag EXISTS
      // predicate avoids duplicate document rows when a PDF has many tags.
      final pattern = '%${escapeLikeWildcards(normalizedQuery)}%';
      where.add("""
        (
          d.name LIKE ? ESCAPE '\\'
          OR c.name LIKE ? ESCAPE '\\'
          OR f.name LIKE ? ESCAPE '\\'
          OR EXISTS (
            SELECT 1 FROM document_tags dt
            INNER JOIN tags t ON t.id = dt.tag_id
            WHERE dt.document_id = d.id AND t.name LIKE ? ESCAPE '\\'
          )
        )
      """);
      args.addAll([pattern, pattern, pattern, pattern]);
    }
    if (cursor != null) {
      where.add('''
        (
          COALESCE(d.last_opened_at, '') < ?
          OR (
            COALESCE(d.last_opened_at, '') = ?
            AND (
              d.name COLLATE NOCASE > ?
              OR (d.name COLLATE NOCASE = ? AND d.id > ?)
            )
          )
        )
      ''');
      args.addAll([
        cursor.lastOpenedAt,
        cursor.lastOpenedAt,
        cursor.name,
        cursor.name,
        cursor.id,
      ]);
    }
    final rows = await db.rawQuery('''
      SELECT d.*, c.name AS category_name,
        (SELECT GROUP_CONCAT(t.name, ', ') FROM document_tags dt
          INNER JOIN tags t ON t.id = dt.tag_id WHERE dt.document_id = d.id) AS tag_names
      FROM documents d
      LEFT JOIN categories c ON c.id = d.category_id
      LEFT JOIN folders f ON f.id = d.folder_id
      WHERE ${where.join(' AND ')}
      ORDER BY COALESCE(d.last_opened_at, '') DESC,
               d.name COLLATE NOCASE ASC, d.id ASC
      LIMIT ?
    ''', [...args, pageSize + 1]);
    final hasMore = rows.length > pageSize;
    final pageRows = hasMore ? rows.take(pageSize).toList() : rows;
    final items = pageRows.map(DocumentRecord.fromMap).toList();
    final last = pageRows.isEmpty ? null : pageRows.last;
    return DocumentPage(
      items: items,
      hasMore: hasMore,
      nextCursor: hasMore && last != null
          ? DocumentPageCursor(
              lastOpenedAt: (last['last_opened_at'] as String?) ?? '',
              name: last['name'] as String,
              id: last['id'] as String,
            )
          : null,
    );
  }

  Future<List<DocumentRecord>> list({String query = '', bool favoritesOnly = false, bool recentOnly = false}) async {
    final db = await _database.database;
    final normalizedQuery = query.trim();
    final where = <String>[
      'd.deleted_at IS NULL',
      if (recentOnly) 'd.last_opened_at IS NOT NULL',
    ];
    final args = <Object?>[];
    if (normalizedQuery.isNotEmpty) {
      final pattern = '%${escapeLikeWildcards(normalizedQuery)}%';
      where.add("""
        (
          d.name LIKE ? ESCAPE '\\'
          OR c.name LIKE ? ESCAPE '\\'
          OR f.name LIKE ? ESCAPE '\\'
          OR EXISTS (
            SELECT 1 FROM document_tags dt
            INNER JOIN tags t ON t.id = dt.tag_id
            WHERE dt.document_id = d.id AND t.name LIKE ? ESCAPE '\\'
          )
        )
      """);
      args.addAll([pattern, pattern, pattern, pattern]);
    }
    final rows = await db.rawQuery(
      '''
      SELECT d.*, c.name AS category_name,
        (SELECT GROUP_CONCAT(t.name, ', ') FROM document_tags dt
          INNER JOIN tags t ON t.id = dt.tag_id WHERE dt.document_id = d.id) AS tag_names
      FROM documents d
      LEFT JOIN categories c ON c.id = d.category_id
      LEFT JOIN folders f ON f.id = d.folder_id
      WHERE ${where.join(' AND ')}
      ORDER BY d.last_opened_at DESC, d.name COLLATE NOCASE ASC
      ''',
      args,
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
    if (Platform.isAndroid) {
      throw StateError('Allow storage access or choose a folder before adding PDFs.');
    }
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
      // Older databases may contain names that bypassed current validation.
      // Never let a legacy dot-segment escape the private DocsGrid root.
      segments.add(FolderRepository.validateFolderName(rows.first['name'] as String));
      currentId = rows.first['parent_id'] as String?;
    }
    var directory = root;
    for (final segment in segments.reversed) {
      directory = Directory(p.join(directory.path, segment));
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<void> moveToFolder(DocumentRecord document, String? folderId, {String? destinationUri}) async {
    await StorageMigrationGate.waitUntilReady();
    if (document.folderId == folderId && destinationUri == null) return;
    final db = await _database.database;
    final storage = StorageLocationService.instance;
    final portableLocations = Platform.isAndroid
        ? await storage.portableDataLocationsIfAvailable()
        : const <String, String>{};
    final selectedRoot = await storage.selectedFolder();

    if (destinationUri == null && folderId == null) {
      destinationUri = portableLocations['documentsUri'] ?? selectedRoot?['uri'];
    } else if (destinationUri == null) {
      final rows = await db.query(
        'folders',
        columns: ['storage_uri_or_relative_path'],
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [folderId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Destination folder no longer exists.');
      final targetFolderId = folderId;
      if (targetFolderId == null) {
        throw StateError('A destination folder is required.');
      }
      destinationUri = rows.first['storage_uri_or_relative_path'] as String?;
      destinationUri ??= await FolderRepository().ensurePhysicalStorageUri(targetFolderId);
    }

    if (Platform.isAndroid && destinationUri == null) {
      throw StateError('Allow storage access or choose a folder before moving PDFs.');
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
      if (copiedToNewLocation) {
        try {
          final sourceDigest = sourceIsShared
              ? await storage.sha256Pdf(sourceUri)
              : (await sha256.bind(File(sourceUri).openRead()).first).toString();
          final copiedDigest = await storage.sha256Pdf(newStorageUri);
          if (copiedDigest != sourceDigest) {
            throw StateError('PDF copy failed SHA-256 verification; the original file was kept.');
          }
        } catch (_) {
          try { await storage.deletePdf(newStorageUri); } catch (_) {}
          rethrow;
        }
      }
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
        if (folderId != null) {
          final activeFolder = await txn.query(
            'folders', columns: ['id'],
            where: 'id = ? AND deleted_at IS NULL',
            whereArgs: [folderId], limit: 1,
          );
          if (activeFolder.isEmpty) throw StateError('Destination folder no longer exists.');
        }
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
      PortableSnapshotEvents.notifyDataChanged();
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
    final portableLocations = Platform.isAndroid
        ? await storage.portableDataLocationsIfAvailable()
        : const <String, String>{};
    final rootUri = portableLocations['documentsUri'] ?? selected?['uri'];
    final folderRootUri = portableLocations['libraryUri'] ?? selected?['uri'];
    if (rootUri == null || folderRootUri == null) {
      throw StateError('Choose a storage folder before starting migration.');
    }
    final db = await _database.database;
    final folderUris = <String, String>{};
    final pendingFolders = <(String?, String)>[(null, folderRootUri)];
    final visitedFolderIds = <String>{};

    // Walk the hierarchy iteratively so deeply nested user folders cannot
    // overflow the Dart call stack during a storage migration.
    while (pendingFolders.isNotEmpty) {
      final (parentId, parentUri) = pendingFolders.removeLast();
      final rows = await db.query(
        'folders',
        columns: ['id', 'name'],
        where: parentId == null
            ? 'parent_id IS NULL'
            : 'parent_id = ?',
        whereArgs: parentId == null ? null : [parentId],
        orderBy: 'name COLLATE NOCASE ASC',
      );
      for (final row in rows) {
        final id = row['id'] as String;
        if (!visitedFolderIds.add(id)) {
          throw StateError('Folder hierarchy contains a cycle or duplicate parent path.');
        }
        // Legacy folder names must pass the same path-segment validation as
        // newly created folders before they reach an external storage provider.
        final name = FolderRepository.validateFolderName(row['name'] as String);
        String childUri;
        try {
          childUri = await storage.findChildUri(parentUri: parentUri, name: name);
        } catch (error) {
          if (!StorageLocationService.isNotFoundError(error)) rethrow;
          childUri = await storage.createDirectory(parentUri: parentUri, name: name);
        }
        folderUris[id] = childUri;
        await db.update(
          'folders',
          {
            'storage_uri_or_relative_path': childUri,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        pendingFolders.add((id, childUri));
      }
    }

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
        // Metadata-only records have no payload to move; retain them for relinking.
        continue;
      }
      final folderId = row['folder_id'] as String?;
      final safePdfName = _safePdfName(name);
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
          name: safePdfName,
        );
        final existingDigest = await storage.sha256Pdf(existingUri);
        if (existingDigest != sourceDigest) {
          throw StateError('A different PDF already exists at the migration destination. The original was kept.');
        }
        destinationUri = existingUri;
      } catch (error) {
        if (!StorageLocationService.isNotFoundError(error)) rethrow;
      }

      if (destinationUri == null) {
        destinationUri = await storage.copyPdf(
          sourceUri: sourceLocation,
          parentUri: parentUri,
          name: safePdfName,
        );
        createdDestination = true;
      }

      try {
        final destinationDigest = await storage.sha256Pdf(destinationUri);
        if (destinationDigest != sourceDigest) {
          throw StateError('Migration copy for "$name" failed SHA-256 verification. The original was kept.');
        }
      } catch (_) {
        if (createdDestination) {
          try { await storage.deletePdf(destinationUri); } catch (_) {}
        }
        rethrow;
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
        PortableSnapshotEvents.notifyDataChanged();
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

  /// Checks whether database rows still reference older writable DocsGrid roots.
  Future<bool> hasLegacyStorageReferences() async {
    final db = await _database.database;
    final documents = await db.query('documents', columns: ['storage_uri']);
    final folders = await db.query(
      'folders',
      columns: ['storage_uri_or_relative_path'],
    );
    return documents.any((row) =>
            StorageLocationService.isLegacyDocsGridStorageLocation(
              row['storage_uri'] as String?,
            )) ||
        folders.any((row) =>
            StorageLocationService.isLegacyDocsGridStorageLocation(
              row['storage_uri_or_relative_path'] as String?,
            ));
  }

  /// Moves older DocsGrid records into Android/media/com.docsgrid. Custom
  /// SAF destinations remain untouched; old PDFs are SHA-256 verified.
  Future<int> migrateLegacyStorageToCanonicalIfNeeded() async {
    if (!Platform.isAndroid) return 0;
    final storage = StorageLocationService.instance;
    if (!await storage.hasAllFilesAccess()) return 0;
    final locations = await storage.portableDataLocationsIfAvailable();
    if (!StorageLocationService.isCanonicalPortableRootUri(locations['rootUri'])) {
      return 0;
    }
    if (!await hasLegacyStorageReferences()) return 0;
    return migrateExistingLibraryToSelectedStorage();
  }

  /// Reconnects a missing or inaccessible PDF to a user-selected copy.
  /// If the record has a SHA-256 value, the replacement must match exactly.
  Future<void> relinkDocument(DocumentRecord document) async {
    await StorageMigrationGate.waitUntilReady();
    final pickedFile = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (pickedFile == null) return;
    File? stagedSource;
    String? createdUri;
    try {
      late final File source;
      final sourcePath = pickedFile.path;
      if (sourcePath != null && sourcePath.isNotEmpty) {
        source = File(sourcePath);
      } else {
        final temp = await getTemporaryDirectory();
        stagedSource = File(p.join(temp.path, 'relink_${_uuid.v4()}.pdf'));
        // Cloud/Files providers may not expose a filesystem path. Stream their
        // bytes into cache so large PDFs do not require a second full-size
        // Uint8List allocation in memory.
        await writeByteStreamToFile(pickedFile.readAsByteStream(), stagedSource);
        source = stagedSource;
      }
      if (!await source.exists()) {
        throw StateError('The selected PDF is no longer available.');
      }
      final header = await source
          .openRead(0, 5)
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b));
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
      final portableLocations = Platform.isAndroid
          ? await storage.portableDataLocationsIfAvailable()
          : const <String, String>{};
      final selectedRoot = await storage.selectedFolder();
      final folderId = rows.first['folder_id'] as String?;
      String? destinationUri;
      if (folderId == null) {
        destinationUri = portableLocations['documentsUri'] ?? selectedRoot?['uri'];
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

      if (Platform.isAndroid && destinationUri == null) {
        throw StateError('Allow storage access or choose a folder before replacing this PDF.');
      }
      String? relativePath;
      if (destinationUri != null) {
        createdUri = await storage.copyPdf(
          sourceUri: Uri.file(source.path).toString(),
          parentUri: destinationUri,
          name: '${document.name}.pdf',
        );
        final copiedDigest = await storage.sha256Pdf(createdUri);
        if (copiedDigest != digest) {
          throw StateError('Replacement PDF verification failed; the existing document reference was not changed.');
        }
      } else {
        final library = await _privateFolderFor(folderId);
        final target = await _uniqueFile(library, '${document.name}.pdf');
        await source.copy(target.path);
        final copiedDigest = (await sha256.bind(target.openRead()).first).toString();
        if (copiedDigest != digest) {
          await target.delete();
          throw StateError('Replacement PDF verification failed; the existing document reference was not changed.');
        }
        createdUri = target.path;
        relativePath = p.relative(target.path, from: p.join(
          (await getApplicationDocumentsDirectory()).path, 'DocsGrid', 'PDFs',
        ));
      }

      try {
        await db.transaction((txn) async {
          final count = await txn.update(
            'documents',
            {
              'storage_uri': createdUri,
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
            'storage_uri': createdUri,
          });
        });
        PortableSnapshotEvents.notifyDataChanged();
      } catch (_) {
        try {
          if (createdUri.startsWith('content://') || createdUri.startsWith('file://')) {
            await storage.deletePdf(createdUri);
          } else {
            final file = File(createdUri);
            if (await file.exists()) await file.delete();
          }
        } catch (_) {}
        rethrow;
      }
    } catch (_) {
      if (createdUri != null) {
        try {
          if (createdUri.startsWith('content://') || createdUri.startsWith('file://')) {
            await StorageLocationService.instance.deletePdf(createdUri);
          } else {
            final file = File(createdUri);
            if (await file.exists()) await file.delete();
          }
        } catch (_) {}
      }
      rethrow;
    } finally {
      if (stagedSource != null) {
        try {
          if (await stagedSource.exists()) await stagedSource.delete();
        } catch (_) {
          // The source selection and saved document remain untouched.
        }
      }
    }
  }

  /// Registers an already-portable PDF in the database without copying it.
  /// Used after reinstall when shared media survived but the private DB did not.
  Future<bool> importExistingSharedPdf({
    required String storageUri,
    required String displayName,
    String? targetFolderId,
  }) async {
    await StorageMigrationGate.waitUntilReady();
    if (!storageUri.startsWith('file://') && !storageUri.startsWith('content://')) {
      throw ArgumentError('Recovery requires a shared-storage file URI.');
    }
    final storage = StorageLocationService.instance;
    final temp = await getTemporaryDirectory();
    final staged = File(p.join(temp.path, 'recover_${_uuid.v4()}.pdf'));
    try {
      await storage.copyPdfToPath(
        sourceUri: storageUri,
        destinationPath: staged.path,
      );
      final header = await staged.openRead(0, 5)
          .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
      if (header.length < 5 || String.fromCharCodes(header) != '%PDF-') {
        throw StateError('Recovered item is not a valid PDF.');
      }
      final digest = (await sha256.bind(staged.openRead()).first).toString();
      final size = await staged.length();
      final db = await _database.database;
      final duplicates = await db.query(
        'documents',
        columns: ['id'],
        where: 'sha256 = ? AND deleted_at IS NULL',
        whereArgs: [digest],
        limit: 1,
      );
      if (duplicates.isNotEmpty) return false;
      if (targetFolderId != null) {
        final folders = await db.query(
          'folders',
          columns: ['id'],
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [targetFolderId],
          limit: 1,
        );
        if (folders.isEmpty) throw StateError('Recovery folder could not be created.');
      }

      final locations = Platform.isAndroid
          ? await storage.portableDataLocationsIfAvailable()
          : const <String, String>{};
      final destinationUri = targetFolderId == null
          ? locations['documentsUri']
          : await FolderRepository().ensurePhysicalStorageUri(targetFolderId);
      if (Platform.isAndroid && destinationUri == null) {
        throw StateError('Allow storage access or choose a folder before recovering PDFs.');
      }
      var recoveredUri = storageUri;
      var storedName = _safePdfName(displayName);
      if (destinationUri != null) {
        var placed = false;
        final baseName = p.basenameWithoutExtension(storedName);
        for (var suffix = 0; suffix < 100; suffix++) {
          final candidateName =
              suffix == 0 ? storedName : '${baseName}_${suffix + 1}.pdf';
          try {
            final existing = await storage.findChildUri(
              parentUri: destinationUri,
              name: candidateName,
            );
            final existingDigest = await storage.sha256Pdf(existing);
            if (existingDigest == digest) {
              recoveredUri = existing;
              storedName = candidateName;
              placed = true;
              break;
            }
          } catch (error) {
            if (!StorageLocationService.isNotFoundError(error)) rethrow;
            final copied = await storage.copyPdf(
              sourceUri: storageUri,
              parentUri: destinationUri,
              name: candidateName,
            );
            try {
              final copiedDigest = await storage.sha256Pdf(copied);
              if (copiedDigest != digest) {
                throw StateError('Recovered PDF did not pass verification.');
              }
            } catch (_) {
              try { await storage.deletePdf(copied); } catch (_) {}
              rethrow;
            }
            recoveredUri = copied;
            storedName = candidateName;
            placed = true;
            break;
          }
        }
        if (!placed) {
          throw StateError('A safe name could not be found for the recovered PDF.');
        }
      }

      final id = _uuid.v4();
      final now = DateTime.now().toUtc().toIso8601String();
      await db.transaction((txn) async {
        await txn.insert('documents', {
          'id': id,
          'name': p.basenameWithoutExtension(storedName),
          'original_name': displayName,
          'storage_uri': recoveredUri,
          'relative_path': null,
          'mime_type': 'application/pdf',
          'size_bytes': size,
          'sha256': digest,
          'folder_id': targetFolderId,
          'extracted_text_status': 'pending',
          'created_at': now,
          'updated_at': now,
          'metadata_json': '{}',
          'source': 'reinstall_recovery',
        });
        await _recordHistory(txn, id, 'recovered_after_reinstall', {
          'storage_uri': recoveredUri,
          'source_uri': storageUri,
          'folder_id': targetFolderId,
        });
      });
      PortableSnapshotEvents.notifyDataChanged();
      // Recovery never deletes the original source file.
      return true;
    } finally {
      if (await staged.exists()) await staged.delete();
    }
  }

  Future<ImportSummary> importScannedPdf(File source, {String? displayName, String? targetFolderUri, String? targetFolderId, String sourceType = 'scanner'}) async {
    await StorageMigrationGate.waitUntilReady();
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
    final portableLocations = Platform.isAndroid
        ? await storage.portableDataLocationsIfAvailable()
        : const <String, String>{};
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
    final destinationUri = targetFolderUri ?? folderUri ??
        (Platform.isAndroid ? portableLocations['documentsUri'] : selected?['uri']) ??
        selected?['uri'];
    if (Platform.isAndroid && destinationUri == null) {
      throw StateError('Allow storage access or choose a folder before adding PDFs.');
    }
    if (destinationUri != null) {
      uri = await storage.copyPdf(
        sourceUri: Uri.file(source.path).toString(),
        parentUri: destinationUri,
        name: safeName,
      );
      try {
        final copiedDigest = await storage.sha256Pdf(uri);
        if (copiedDigest != digest) {
          throw StateError('Scanned PDF failed SHA-256 verification in selected storage.');
        }
      } catch (_) {
        try { await storage.deletePdf(uri); } catch (_) {}
        rethrow;
      }
    } else {
      // Keep scanner imports in the same nested private-folder layout used by
      // ordinary imports; metadata folder_id and the on-disk path must agree.
      final library = await _privateFolderFor(targetFolderId);
      final target = await _uniqueFile(library, safeName);
      await source.copy(target.path);
      final copiedDigest = (await sha256.bind(target.openRead()).first).toString();
      if (copiedDigest != digest) {
        await target.delete();
        throw StateError('Scanned PDF verification failed.');
      }
      final base = await getApplicationDocumentsDirectory();
      uri = target.path;
      relativePath = p.relative(
        target.path,
        from: p.join(base.path, 'DocsGrid', 'PDFs'),
      );
    }

    final now = DateTime.now().toUtc().toIso8601String();
    try {
      await db.transaction((txn) async {
        final existingNow = await txn.query('documents', columns: ['id'],
          where: 'sha256 = ? AND deleted_at IS NULL', whereArgs: [digest], limit: 1);
        if (existingNow.isNotEmpty) throw _DuplicatePdfException();
        if (targetFolderId != null) {
          final activeFolder = await txn.query('folders', columns: ['id'],
            where: 'id = ? AND deleted_at IS NULL', whereArgs: [targetFolderId], limit: 1);
          if (activeFolder.isEmpty) throw StateError('Destination folder no longer exists.');
        }
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
      PortableSnapshotEvents.notifyDataChanged();
    } catch (error) {
      try {
        if (uri.startsWith('content://') || uri.startsWith('file://')) {
          await storage.deletePdf(uri);
        } else {
          final file = File(uri);
          if (await file.exists()) await file.delete();
        }
      } catch (_) {}
      if (error is _DuplicatePdfException) {
        return const ImportSummary(added: 0, duplicates: 1, failed: 0);
      }
      rethrow;
    }
    return const ImportSummary(added: 1, duplicates: 0, failed: 0);
  }

  /// Moves a PDF discovered in shared storage into the managed Grid library.
  /// The source is deleted only after the copied PDF has been verified and its
  /// database record has committed successfully.
  Future<ImportSummary> moveExternalPdfToGrid({
    required String sourceUri,
    required String displayName,
    String? targetFolderId,
  }) async {
    final storage = StorageLocationService.instance;
    final tempDirectory = await getTemporaryDirectory();
    final staged = File(p.join(
      tempDirectory.path,
      'docsgrid_move_${DateTime.now().microsecondsSinceEpoch}.pdf',
    ));
    try {
      await storage.copyPdfToPath(
        sourceUri: sourceUri,
        destinationPath: staged.path,
      );
      final imported = await importScannedPdf(
        staged,
        displayName: displayName,
        targetFolderId: targetFolderId,
        sourceType: 'phone_storage_move',
      );
      if (imported.added == 0) {
        // A duplicate already exists in Grid. Keep the Phone original intact.
        return imported;
      }
      // importScannedPdf verifies SHA-256 and commits the Grid record before
      // this destructive step. If deletion fails, both copies remain safe.
      await storage.deletePdf(sourceUri);
      return imported;
    } finally {
      try {
        if (await staged.exists()) await staged.delete();
      } catch (_) {}
    }
  }

  /// Archives an external PDF in the app's Recycle Bin before deleting its
  /// original. Existing Grid duplicates are deliberately left untouched.
  Future<bool> moveExternalPdfToTrash({
    required String sourceUri,
    required String displayName,
  }) async {
    final storage = StorageLocationService.instance;
    final temp = await getTemporaryDirectory();
    final staged = File(p.join(
      temp.path,
      'docsgrid_trash_${DateTime.now().microsecondsSinceEpoch}.pdf',
    ));
    try {
      await storage.copyPdfToPath(
        sourceUri: sourceUri,
        destinationPath: staged.path,
      );
      final imported = await importScannedPdf(
        staged,
        displayName: displayName,
        sourceType: 'phone_storage_recycle_bin',
      );
      if (imported.added != 1) return false;
      final digest = (await sha256.bind(staged.openRead()).first).toString();
      final db = await _database.database;
      final rows = await db.query(
        'documents',
        where: 'sha256 = ? AND deleted_at IS NULL',
        whereArgs: [digest],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('The archived PDF record could not be found; original kept.');
      }
      final archivedDocument = DocumentRecord.fromMap(rows.first);
      // Delete the Phone original only after the Grid copy is verified. If
      // Android denies deletion, keep the imported copy active and recoverable;
      // do not leave a failed action half-hidden in Recycle Bin.
      await storage.deletePdf(sourceUri);
      await moveToTrash(archivedDocument);
      return true;
    } finally {
      try {
        if (await staged.exists()) await staged.delete();
      } catch (_) {}
    }
  }

  Future<ImportSummary> importPdfs({
    Future<ImportDecision?> Function(String suggestedName, String? suggestedCategoryId, List<ImportCategoryOption> categories)? review,
    String? targetFolderId,
  }) async {
    await StorageMigrationGate.waitUntilReady();
    final pickedFiles = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (pickedFiles.isEmpty) {
      return const ImportSummary(added: 0, duplicates: 0, failed: 0);
    }

    final storage = StorageLocationService.instance;
    final selectedFolder = await storage.selectedFolder();
    final portableLocations = Platform.isAndroid
        ? await storage.portableDataLocationsIfAvailable()
        : const <String, String>{};
    final db = await _database.database;
    var added = 0;
    var duplicates = 0;
    var failed = 0;
    var skipped = 0;
    final errors = <String>[];
    final categoryRows = await db.query('categories', columns: ['id', 'name'], orderBy: 'name COLLATE NOCASE');
    final categoryOptions = categoryRows.map((row) => ImportCategoryOption(
      id: row['id'] as String,
      name: row['name'] as String,
    )).toList(growable: false);

    for (final picked in pickedFiles) {
      String? createdUri;
      File? stagedSource;
      try {
        final sourcePath = picked.path;
        late final File sourceFile;
        final candidate = sourcePath == null || sourcePath.isEmpty
            ? null
            : File(sourcePath);
        if (candidate != null && await candidate.exists()) {
          sourceFile = candidate;
        } else {
          // Some document providers return a path that becomes unreadable
          // after the picker closes. Fall back to the provider stream instead
          // of failing solely because that temporary path is stale.
          final temp = await getTemporaryDirectory();
          stagedSource = File(p.join(temp.path, 'import_${_uuid.v4()}.pdf'));
          await writeByteStreamToFile(picked.readAsByteStream(), stagedSource);
          if (!await stagedSource.exists() || await stagedSource.length() == 0) {
            throw StateError('The selected PDF could not be read from the document provider.');
          }
          sourceFile = stagedSource;
        }

        final header = await sourceFile.openRead(0, 5)
            .fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        if (header.length < 5 || String.fromCharCodes(header) != '%PDF-') {
          failed++;
          errors.add('${picked.name}: the selected file is not a valid PDF (missing the %PDF- signature).');
          continue;
        }
        final digest = (await sha256.bind(sourceFile.openRead()).first).toString();
        final sizeBytes = await sourceFile.length();
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
        final decision = review == null || pickedFiles.length != 1
            ? ImportDecision(name: suggestedName, categoryId: suggestedCategoryId)
            : await review(suggestedName, suggestedCategoryId, categoryOptions);
        if (decision == null) {
          skipped++;
          continue;
        }
        final effectiveTargetFolderId = review != null && pickedFiles.length == 1
            ? decision.targetFolderId
            : targetFolderId;
        final targetFolderUri = effectiveTargetFolderId == null
            ? null
            : await FolderRepository().ensurePhysicalStorageUri(effectiveTargetFolderId);
        final destination = resolvePdfImportDestination(
          isAndroid: Platform.isAndroid,
          portableDocumentsUri: portableLocations['documentsUri'],
          selectedFolderUri: selectedFolder?['uri'],
          targetFolderUri: targetFolderUri,
        );
        if (destination.requiresStorageSetup) {
          throw StateError('Allow storage access or choose a folder before adding PDFs.');
        }
        final destinationFolderUri = destination.uri;
        // Base the private-storage fallback on the resolved destination, not
        // merely on whether a folder preference exists. A selected SAF folder
        // can be the only available Android destination when portable storage
        // is unavailable (for example, without MANAGE_EXTERNAL_STORAGE).
        final library = destination.usesPrivateStorage
            ? await _privateFolderFor(effectiveTargetFolderId)
            : null;
        final safeName = _safePdfName(decision.name);
        final selectedCategoryId = categoryOptions.any((item) => item.id == decision.categoryId)
            ? decision.categoryId
            : null;
        late final String storedName;
        late final String? relativePath;
        if (destinationFolderUri != null) {
          createdUri = await storage.copyPdf(
            sourceUri: Uri.file(sourceFile.path).toString(),
            parentUri: destinationFolderUri,
            name: safeName,
          );
          final copiedDigest = await storage.sha256Pdf(createdUri);
          if (copiedDigest != digest) {
            throw StateError('Imported PDF failed SHA-256 verification in selected storage.');
          }
          storedName = p.basenameWithoutExtension(safeName);
          relativePath = null;
        } else {
          final target = await _uniqueFile(library!, safeName);
          await sourceFile.copy(target.path);
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
          final existingNow = await txn.query('documents', columns: ['id'],
            where: 'sha256 = ? AND deleted_at IS NULL', whereArgs: [digest], limit: 1);
          if (existingNow.isNotEmpty) throw _DuplicatePdfException();
          if (effectiveTargetFolderId != null) {
            final activeFolder = await txn.query('folders', columns: ['id'],
              where: 'id = ? AND deleted_at IS NULL', whereArgs: [effectiveTargetFolderId], limit: 1);
            if (activeFolder.isEmpty) throw StateError('Destination folder no longer exists.');
          }
          if (selectedCategoryId != null) {
            final activeCategory = await txn.query('categories', columns: ['id'],
              where: 'id = ?', whereArgs: [selectedCategoryId], limit: 1);
            if (activeCategory.isEmpty) throw StateError('Selected category no longer exists.');
          }
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
            'folder_id': effectiveTargetFolderId,
            'extracted_text_status': 'pending',
            'created_at': now,
            'updated_at': now,
            'metadata_json': '{}',
            'source': 'file_picker',
          });
          await _recordHistory(txn, documentId, 'imported', {'name': storedName});
        });
        PortableSnapshotEvents.notifyDataChanged();
        added++;
      } catch (error) {
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
        if (error is _DuplicatePdfException) {
          duplicates++;
        } else {
          failed++;
          errors.add('${picked.name}: $error');
        }
      } finally {
        if (stagedSource != null) {
          try {
            if (await stagedSource.exists()) await stagedSource.delete();
          } catch (_) {
            // Never let cache cleanup affect the imported source or DB record.
          }
        }
      }
    }
    return ImportSummary(added: added, duplicates: duplicates, failed: failed, skipped: skipped, errors: errors);
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
    final stem = p.basenameWithoutExtension(cleaned);
    final boundedStem = String.fromCharCodes(stem.runes.take(120));
    final safeStem = boundedStem.isEmpty ? 'Document' : boundedStem;
    return '$safeStem.pdf';
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
    PortableSnapshotEvents.notifyDataChanged();
    await _reconcileReminders();
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
  Future<void> _reconcileReminders() async {
    final db = await _database.database;
    final rows = await db.rawQuery('''
      SELECT r.*
      FROM reminders r
      LEFT JOIN documents d ON d.id = r.document_id
      WHERE r.enabled = 1
        AND r.status NOT IN (?, ?)
        AND (r.document_id IS NULL OR d.deleted_at IS NULL)
      ORDER BY r.remind_at_utc ASC
    ''', ['completed', 'cancelled']);
    try {
      await ReminderNotifications.instance.reconcile(rows);
    } catch (_) {
      // Trash and restore are database/file operations; OS notification
      // failures must not make a completed document action appear to fail.
    }
  }

  Future<void> setFavorite(DocumentRecord document, bool favorite) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'documents',
        columns: ['metadata_json'],
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [document.id],
        limit: 1,
      );
      if (rows.isEmpty) return;
      Map<String, dynamic> metadata = <String, dynamic>{};
      try {
        final decoded = jsonDecode((rows.first['metadata_json'] as String?) ?? '{}');
        if (decoded is Map<String, dynamic>) metadata = decoded;
      } catch (_) {
        // A damaged optional metadata blob must not block a basic favorite toggle.
      }
      metadata['favorite'] = favorite;
      final count = await txn.update(
        'documents',
        {
          'metadata_json': jsonEncode(metadata),
          'is_favorite': favorite ? 1 : 0,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [document.id],
      );
      if (count == 0) return;
      await _recordHistory(
        txn,
        document.id,
        favorite ? 'favorited' : 'unfavorited',
        {},
      );
    });
    PortableSnapshotEvents.notifyDataChanged();
  }

  Future<DocumentRecord?> getById(String id) async {
    final db = await _database.database;
    final rows = await db.rawQuery('''
      SELECT d.*, c.name AS category_name,
        (SELECT GROUP_CONCAT(t.name, ', ') FROM document_tags dt
          INNER JOIN tags t ON t.id = dt.tag_id WHERE dt.document_id = d.id) AS tag_names
      FROM documents d
      LEFT JOIN categories c ON c.id = d.category_id
      WHERE d.id = ? AND d.deleted_at IS NULL
      LIMIT 1
    ''', [id]);
    if (rows.isEmpty) return null;
    return DocumentRecord.fromMap(rows.first);
  }

  Future<List<DocumentRecord>> listAllStarred() async {
    final db = await _database.database;
    final rows = await db.rawQuery('''
      SELECT d.*, c.name AS category_name,
        (SELECT GROUP_CONCAT(t.name, ', ') FROM document_tags dt
          INNER JOIN tags t ON t.id = dt.tag_id WHERE dt.document_id = d.id) AS tag_names
      FROM documents d
      LEFT JOIN categories c ON c.id = d.category_id
      WHERE d.deleted_at IS NULL AND d.is_favorite = 1
      ORDER BY COALESCE(d.last_opened_at, d.created_at) DESC,
               d.name COLLATE NOCASE ASC, d.id ASC
    ''');
    return rows.map(DocumentRecord.fromMap).toList(growable: false);
  }

  Future<void> clearOpenedHistory() async {
    final db = await _database.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'documents',
        columns: ['id'],
        where: 'deleted_at IS NULL AND last_opened_at IS NOT NULL',
      );
      await txn.update(
        'documents',
        {'last_opened_at': null},
        where: 'deleted_at IS NULL',
      );
      for (final row in rows) {
        await _recordHistory(txn, row['id'] as String, 'recent_cleared', {});
      }
    });
    PortableSnapshotEvents.notifyDataChanged();
  }

  Future<DocumentRecord> copyDocument(
    DocumentRecord document, {String? targetFolderId}
  ) async {
    await StorageMigrationGate.waitUntilReady();
    final sourceUri = document.storagePath;
    final storage = StorageLocationService.instance;
    final baseName = document.name;
    final db = await _database.database;
    final newId = _uuid.v4();
    final newName = '$baseName copy';
    String newUri;
    if (sourceUri.startsWith('content://') || sourceUri.startsWith('file://')) {
      final parent = targetFolderId == null
          ? (Platform.isAndroid
              ? (await storage.portableDataLocationsIfAvailable())['documentsUri']
              : (await storage.selectedFolder())?['uri'])
          : await FolderRepository().ensurePhysicalStorageUri(targetFolderId);
      if (parent == null) throw StateError('No writable destination is available for this PDF.');
      newUri = await storage.copyPdf(
        sourceUri: sourceUri,
        parentUri: parent,
        name: '$newName.pdf',
      );
    } else {
      final source = File(sourceUri);
      if (!await source.exists()) throw StateError('Original PDF is missing.');
      final folder = await _privateFolderFor(targetFolderId);
      final target = await _uniqueFile(folder, '$newName.pdf');
      await source.copy(target.path);
      newUri = target.path;
    }
    final digest = newUri.startsWith('content://') || newUri.startsWith('file://')
        ? await storage.sha256Pdf(newUri)
        : (await sha256.bind(File(newUri).openRead()).first).toString();
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      await db.insert('documents', {
        'id': newId,
        'name': newName,
        'original_name': '$newName.pdf',
        'storage_uri': newUri,
        'relative_path': null,
        'mime_type': 'application/pdf',
        'size_bytes': document.sizeBytes,
        'sha256': digest,
        'folder_id': targetFolderId,
        'category_id': document.categoryId,
        'extracted_text_status': 'pending',
        'created_at': now,
        'updated_at': now,
        'last_opened_at': null,
        'deleted_at': null,
        'source': 'copy',
        'metadata_json': jsonEncode({'favorite': false}),
        'is_favorite': 0,
      });
    } catch (_) {
      try {
        if (newUri.startsWith('content://') || newUri.startsWith('file://')) {
          await storage.deletePdf(newUri);
        } else {
          await File(newUri).delete();
        }
      } catch (_) {}
      rethrow;
    }
    final created = await getById(newId);
    if (created == null) throw StateError('Copied PDF was not saved in the library.');
    await db.transaction((txn) async {
      await _recordHistory(txn, newId, 'copied', {'from': document.id});
    });
    PortableSnapshotEvents.notifyDataChanged();
    return created;
  }

  Future<void> markOpened(DocumentRecord document) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      final count = await txn.update(
        'documents',
        {'last_opened_at': DateTime.now().toUtc().toIso8601String()},
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [document.id],
      );
      if (count == 0) return;
      await _recordHistory(txn, document.id, 'opened', {});
    });
    PortableSnapshotEvents.notifyDataChanged();
  }

  Future<List<DocumentRecord>> listTrash({String query = ''}) async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      '''
      SELECT d.*, c.name AS category_name
      FROM documents d
      LEFT JOIN categories c ON c.id = d.category_id
      WHERE d.deleted_at IS NOT NULL
        AND COALESCE(d.trash_operation_id, '') = ''
        AND d.name LIKE ? ESCAPE '\\'
      ORDER BY d.deleted_at DESC
      ''',
      ['%${escapeLikeWildcards(query.trim())}%'],
    );
    return rows.map(DocumentRecord.fromMap).toList();
  }

  /// Counts only individually recycled PDFs. Folder-grouped PDFs are counted
  /// by their visible folder root and are not duplicated in the PDF section.
  Future<int> trashCount() async {
    final db = await _database.database;
    return Sqflite.firstIntValue(await db.rawQuery(
      "SELECT COUNT(*) FROM documents WHERE deleted_at IS NOT NULL AND COALESCE(trash_operation_id, '') = ''",
    )) ?? 0;
  }

  Future<void> restoreFromTrash(DocumentRecord document) async {
    await StorageMigrationGate.waitUntilReady();
    final db = await _database.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'documents',
        columns: ['folder_id', 'trash_operation_id'],
        where: 'id = ? AND deleted_at IS NOT NULL',
        whereArgs: [document.id],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('PDF is no longer in the Recycle Bin.');
      if ((rows.single['trash_operation_id'] as String?)?.isNotEmpty == true) {
        throw StateError('Restore the containing folder from Recycle Bin first.');
      }
      final parentId = rows.single['folder_id'] as String?;
      if (parentId != null) {
        final parent = await txn.query(
          'folders', columns: ['id'],
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [parentId], limit: 1,
        );
        if (parent.isEmpty) throw StateError('Restore the original parent folder first.');
      }
      final count = await txn.update('documents', {
        'deleted_at': null,
        'trash_operation_id': null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, where: 'id = ? AND deleted_at IS NOT NULL', whereArgs: [document.id]);
      if (count == 0) throw StateError('PDF is no longer in the Recycle Bin.');
      await _recordHistory(txn, document.id, 'restored', {});
    });
    PortableSnapshotEvents.notifyDataChanged();
    await _reconcileReminders();
  }

  Future<void> moveToTrash(DocumentRecord document) async {
    await StorageMigrationGate.waitUntilReady();
    final db = await _database.database;
    await db.transaction((txn) async {
      final changed = await txn.update('documents', {
        'deleted_at': DateTime.now().toUtc().toIso8601String(),
        'trash_operation_id': null,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, where: 'id = ? AND deleted_at IS NULL', whereArgs: [document.id]);
      if (changed == 0) throw StateError('PDF record is already in the Recycle Bin.');
      await _recordHistory(txn, document.id, 'moved_to_recycle_bin', {});
    });
    PortableSnapshotEvents.notifyDataChanged();
    await _reconcileReminders();
  }

  Future<void> rename(DocumentRecord document, String newName) async {
    await StorageMigrationGate.waitUntilReady();
    final cleaned = newName.trim();
    if (cleaned.isEmpty) throw ArgumentError('Name cannot be empty.');
    final rawBase = p.basenameWithoutExtension(cleaned)
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .trim();
    final safeBase = String.fromCharCodes(rawBase.runes.take(120));
    if (safeBase.isEmpty) throw ArgumentError('Name is not valid.');
    final safeName = '$safeBase.pdf';
    if (safeBase == document.name) return;
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
      PortableSnapshotEvents.notifyDataChanged();
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
    await StorageMigrationGate.waitUntilReady();
    final db = await _database.database;
    final trashed = await db.query(
      'documents',
      columns: ['storage_uri', 'trash_operation_id'],
      where: 'id = ? AND deleted_at IS NOT NULL',
      whereArgs: [document.id],
      limit: 1,
    );
    if (trashed.isEmpty) {
      throw StateError('Only documents in the Recycle Bin can be permanently deleted.');
    }
    if ((trashed.first['trash_operation_id'] as String?)?.isNotEmpty == true) {
      throw StateError('This PDF belongs to a deleted folder. Empty the folder entry in Recycle Bin instead.');
    }
    final currentStoragePath = (trashed.first['storage_uri'] as String?)?.trim();
    if (currentStoragePath == null || currentStoragePath.isEmpty) {
      throw StateError('The PDF has no saved storage location; repair or relink it before permanent deletion.');
    }
    final reminderRows = await db.query(
      'reminders',
      columns: ['id'],
      where: 'document_id = ?',
      whereArgs: [document.id],
    );

    // Keep the database record until the physical delete succeeds. The
    // Recycle Bin remains the recovery point if storage access is unavailable.
    if (currentStoragePath.startsWith('content://') ||
        currentStoragePath.startsWith('file://')) {
      await StorageLocationService.instance.deletePdf(currentStoragePath);
    } else {
      final file = File(currentStoragePath);
      if (await file.exists()) await file.delete();
    }

    await db.transaction((txn) async {
      await _recordHistory(
        txn,
        null,
        'permanently_deleted',
        {'document_id': document.id, 'name': document.name},
      );
      await txn.delete(
        'reminders',
        where: 'document_id = ?',
        whereArgs: [document.id],
      );
      final deleted = await txn.delete(
        'documents',
        where: 'id = ? AND deleted_at IS NOT NULL',
        whereArgs: [document.id],
      );
      if (deleted == 0) {
        throw StateError('The document is no longer in the Recycle Bin.');
      }
    });
    PortableSnapshotEvents.notifyDataChanged();

    // If OS cancellation fails, startup/resume reconciliation removes the
    // orphaned pending notification because its reminder row no longer exists.
    for (final row in reminderRows) {
      try {
        await ReminderNotifications.instance.cancel(row['id'] as String);
      } catch (_) {}
    }
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
