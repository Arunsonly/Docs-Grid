import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/storage/storage_location_service.dart';
import '../../../core/storage/portable_snapshot_events.dart';
import '../../../core/storage/storage_migration_gate.dart';
import '../domain/folder.dart';

class FolderOption {
  const FolderOption({required this.folder, required this.path});
  final Folder folder;
  final String path;
}

class FolderRepository {
  FolderRepository({AppDatabase? database})
      : _database = database ?? AppDatabase.instance;

  final AppDatabase _database;
  static const _uuid = Uuid();

  /// Validates a folder name before it is used as a path segment.
  /// Dot segments are rejected to prevent escaping the private library root.
  /// Maps a private-library document path after an ancestor folder is renamed.
  /// Provider URIs and paths outside the renamed subtree are left untouched.
  static String? remapPrivateDocumentPath({
    required String oldFolderPath,
    required String newFolderPath,
    required String documentUri,
  }) {
    if (documentUri.startsWith('content://') ||
        documentUri.startsWith('file://') ||
        !p.isWithin(oldFolderPath, documentUri)) {
      return null;
    }
    final relative = p.relative(documentUri, from: oldFolderPath);
    return p.join(newFolderPath, relative);
  }

  static String validateFolderName(String name) {
    final cleaned = name.trim();
    if (cleaned.isEmpty) throw ArgumentError('Folder name cannot be empty.');
    if (cleaned == '.' || cleaned == '..') {
      throw ArgumentError('Folder name cannot be . or ..');
    }
    if (cleaned.contains('/') || cleaned.contains('\\')) {
      throw ArgumentError('Folder name cannot contain / or \\.');
    }
    if (cleaned.length > 255 ||
        cleaned.codeUnits.any((unit) => unit < 32 || unit == 127)) {
      throw ArgumentError('Folder name is too long or contains control characters.');
    }
    return cleaned;
  }

  Future<List<Folder>> childrenOf(String? parentId) async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      '''
      SELECT f.*,
        (SELECT COUNT(*) FROM documents d
          WHERE d.folder_id = f.id AND d.deleted_at IS NULL) AS pdf_count
      FROM folders f
      WHERE ${parentId == null ? 'f.parent_id IS NULL' : 'f.parent_id = ?'}
        AND f.deleted_at IS NULL
      ORDER BY f.sort_order ASC, f.name COLLATE NOCASE ASC
      ''',
      parentId == null ? const [] : [parentId],
    );
    final storage = StorageLocationService.instance;
    final visible = <Folder>[];
    final staleIds = <String>[];
    for (final row in rows) {
      final folder = Folder.fromMap(row);
      final uri = folder.storageUri;
      if (uri == null ||
          (!uri.startsWith('content://') && !uri.startsWith('file://'))) {
        visible.add(folder);
        continue;
      }
      try {
        // A folder can be deleted outside DocsGrid (for example in Samsung
        // My Files). Do not keep showing its stale database row.
        await storage.listDirectory(uri);
        visible.add(folder);
      } on PlatformException catch (error) {
        final details = '${error.message ?? ''} ${error.details ?? ''}';
        final missing = error.code == 'NOT_FOUND' ||
            (error.code == 'STORAGE_ERROR' &&
                (details.contains('FileNotFoundException') ||
                 details.contains('Missing file')));
        if (!missing) rethrow;
        staleIds.add(folder.id);
      }
    }
    if (staleIds.isNotEmpty) {
      final now = DateTime.now().toUtc().toIso8601String();
      await db.transaction((txn) async {
        for (final staleId in staleIds) {
          await txn.update(
            'folders',
            {'deleted_at': now, 'updated_at': now},
            where: 'id = ? AND deleted_at IS NULL',
            whereArgs: [staleId],
          );
        }
      });
      PortableSnapshotEvents.notifyDataChanged();
    }
    return visible;
  }

  /// Persists the visual order of the active children of one parent.
  /// The supplied ids must be an exact permutation of that parent's folders.
  Future<void> reorderChildren(String? parentId, List<String> orderedIds) async {
    await StorageMigrationGate.waitUntilReady();
    final db = await _database.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'folders',
        columns: ['id'],
        where: parentId == null
            ? 'parent_id IS NULL AND deleted_at IS NULL'
            : 'parent_id = ? AND deleted_at IS NULL',
        whereArgs: parentId == null ? null : [parentId],
        orderBy: 'sort_order ASC, name COLLATE NOCASE ASC',
      );
      final currentIds = rows.map((row) => row['id'] as String).toSet();
      if (orderedIds.length != currentIds.length ||
          orderedIds.toSet().length != orderedIds.length ||
          !orderedIds.toSet().containsAll(currentIds)) {
        throw StateError('Folder order changed. Refresh and try again.');
      }
      final batch = txn.batch();
      for (var index = 0; index < orderedIds.length; index++) {
        batch.update(
          'folders',
          {'sort_order': index},
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [orderedIds[index]],
        );
      }
      await batch.commit(noResult: true);
    });
    PortableSnapshotEvents.notifyDataChanged();
  }

  Future<List<FolderOption>> allFoldersWithPaths() async {
    final result = <FolderOption>[];
    final visited = <String>{};
    final stack = <({Folder folder, String path})>[];
    final roots = await childrenOf(null);
    for (final folder in roots.reversed) {
      stack.add((folder: folder, path: folder.name));
    }
    while (stack.isNotEmpty) {
      final entry = stack.removeLast();
      if (!visited.add(entry.folder.id)) {
        throw StateError('Folder hierarchy contains a cycle or duplicate reference.');
      }
      result.add(FolderOption(folder: entry.folder, path: entry.path));
      final children = await childrenOf(entry.folder.id);
      for (final child in children.reversed) {
        stack.add((folder: child, path: '${entry.path} / ${child.name}'));
      }
    }
    return result;
  }

  /// Ensures a virtual folder and its ancestors exist in the selected
  /// physical storage tree. Returns null when the library is app-private.
  Future<String?> ensurePhysicalStorageUri(String folderId) async {
    await StorageMigrationGate.waitUntilReady();
    final db = await _database.database;
    final storage = StorageLocationService.instance;
    final selectedRoot = await storage.selectedFolder();
    final portableLocations = Platform.isAndroid
        ? await storage.portableDataLocationsIfAvailable()
        : const <String, String>{};
    final defaultLibraryRoot = portableLocations['libraryUri'];

    final chain = <({String id, String name, String? parentId, String? uri})>[];
    final visited = <String>{};
    String? currentId = folderId;
    while (currentId != null) {
      if (!visited.add(currentId)) throw StateError('Folder hierarchy contains a cycle.');
      final rows = await db.query(
        'folders',
        columns: ['name', 'parent_id', 'storage_uri_or_relative_path'],
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [currentId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Folder no longer exists.');
      final row = rows.first;
      chain.add((
        id: currentId,
        name: validateFolderName(row['name'] as String),
        parentId: row['parent_id'] as String?,
        uri: row['storage_uri_or_relative_path'] as String?,
      ));
      currentId = row['parent_id'] as String?;
    }

    String? parentUri = defaultLibraryRoot ?? selectedRoot?['uri'];
    for (final folder in chain.reversed) {
      var childUri = folder.uri;
      // Older full restores stored absolute filesystem paths in this URI column.
      // Convert those legacy values to file:// URIs before passing them to the
      // Android channel, which dispatches file:// and SAF content:// separately.
      if (Platform.isAndroid &&
          childUri != null &&
          childUri.startsWith('/')) {
        childUri = Uri.file(childUri).toString();
        await db.update(
          'folders',
          {
            'storage_uri_or_relative_path': childUri,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [folder.id],
        );
      }
      if (childUri == null && parentUri != null) {
        try {
          childUri = await StorageLocationService.instance.findChildUri(
            parentUri: parentUri,
            name: folder.name,
          );
        } catch (error) {
          if (!StorageLocationService.isNotFoundError(error)) rethrow;
          childUri = await StorageLocationService.instance.createDirectory(
            parentUri: parentUri,
            name: folder.name,
          );
        }
        await db.update(
          'folders',
          {
            'storage_uri_or_relative_path': childUri,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [folder.id],
        );
      }
      if (childUri == null) return null;
      parentUri = childUri;
    }
    return parentUri;
  }

  Future<Folder> create({required String name, String? parentId}) async {
    await StorageMigrationGate.waitUntilReady();
    final cleaned = validateFolderName(name);
    final db = await _database.database;
    final storage = StorageLocationService.instance;
    if (parentId != null) {
      final parent = await db.query(
        'folders', columns: ['id'],
        where: 'id = ? AND deleted_at IS NULL', whereArgs: [parentId], limit: 1,
      );
      if (parent.isEmpty) throw StateError('Parent folder no longer exists.');
    }
    final existingBeforeCreate = await db.query(
      'folders',
      columns: ['id', 'deleted_at'],
      where: 'parent_id IS ? AND name = ? COLLATE NOCASE',
      whereArgs: [parentId, cleaned],
      orderBy: 'deleted_at IS NULL DESC',
      limit: 1,
    );
    if (existingBeforeCreate.isNotEmpty) {
      if (existingBeforeCreate.single['deleted_at'] != null) {
        throw StateError(
          'A folder with this name is in the Recycle Bin. Restore it or permanently delete it before creating another folder with the same name.',
        );
      }
      throw StateError('A folder with this name already exists here.');
    }
    final selectedRoot = await storage.selectedFolder();
    final portableLocations = Platform.isAndroid
        ? await storage.portableDataLocationsIfAvailable()
        : const <String, String>{};
    final String? selectedRootUri =
        portableLocations['libraryUri'] ?? selectedRoot?['uri'];
    if (Platform.isAndroid && selectedRootUri == null) {
      throw StateError('Allow storage access or choose a folder before creating folders.');
    }
    final String? parentStorageUri = parentId == null
        ? selectedRootUri
        : await ensurePhysicalStorageUri(parentId);
    String? physicalUri;
    if (parentStorageUri != null) {
      physicalUri = await storage.createDirectory(parentUri: parentStorageUri, name: cleaned);
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final folder = Folder(
      id: _uuid.v4(),
      name: cleaned,
      parentId: parentId,
      storageUri: physicalUri,
      createdAt: DateTime.parse(now),
      updatedAt: DateTime.parse(now),
    );
    try {
      await db.transaction((txn) async {
        if (parentId != null) {
          final parent = await txn.query(
            'folders', columns: ['id'],
            where: 'id = ? AND deleted_at IS NULL', whereArgs: [parentId], limit: 1,
          );
          if (parent.isEmpty) throw StateError('Parent folder no longer exists.');
        }
        final duplicates = await txn.query(
          'folders',
          columns: ['id'],
          where: 'parent_id IS ? AND name = ? COLLATE NOCASE AND deleted_at IS NULL',
          whereArgs: [parentId, cleaned],
          limit: 1,
        );
        if (duplicates.isNotEmpty) {
          throw StateError('A folder with this name already exists here.');
        }
        final maxOrderRows = await txn.rawQuery(
          parentId == null
              ? 'SELECT COALESCE(MAX(sort_order), -1) AS max_order FROM folders WHERE parent_id IS NULL AND deleted_at IS NULL'
              : 'SELECT COALESCE(MAX(sort_order), -1) AS max_order FROM folders WHERE parent_id = ? AND deleted_at IS NULL',
          parentId == null ? null : [parentId],
        );
        final nextOrder = ((maxOrderRows.first['max_order'] as int?) ?? -1) + 1;
        await txn.insert('folders', {
          'id': folder.id,
          'sort_order': nextOrder,
          'name': folder.name,
          'parent_id': folder.parentId,
          'storage_uri_or_relative_path': physicalUri,
          'created_at': now,
          'updated_at': now,
        });
      });
      PortableSnapshotEvents.notifyDataChanged();
    } catch (_) {
      if (physicalUri != null) {
        try { await storage.deletePdf(physicalUri); } catch (_) {}
      }
      rethrow;
    }
    return folder;
  }

  Future<void> rename(String id, String name) async {
    await StorageMigrationGate.waitUntilReady();
    final cleaned = validateFolderName(name);
    final db = await _database.database;
    final rows = await db.query(
      'folders',
      columns: ['name', 'parent_id', 'storage_uri_or_relative_path'],
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Folder no longer exists.');
    final oldName = rows.first['name'] as String;
    if (oldName == cleaned) return;
    final oldUri = rows.first['storage_uri_or_relative_path'] as String?;
    final storage = StorageLocationService.instance;
    final renamedUri = oldUri == null
        ? null
        : await storage.renamePdf(uri: oldUri, name: cleaned);

    final folderUriUpdates = <String, String>{};
    final documentUriUpdates = <String, String>{};
    final privateDocumentUpdates = <String, Map<String, Object?>>{};
    final traversedFolders = <String>{};
    Directory? renamedPrivateDirectory;
    String? oldPrivatePath;

    try {
      if (renamedUri != null) {
        final pendingFolders = <(String, String)>[(id, renamedUri)];
        while (pendingFolders.isNotEmpty) {
          final (parentId, parentUri) = pendingFolders.removeLast();
          if (!traversedFolders.add(parentId)) {
            throw StateError('Folder hierarchy contains a cycle.');
          }
          final childFolders = await db.query(
            'folders',
            columns: ['id', 'name'],
            where: 'parent_id = ? AND deleted_at IS NULL',
            whereArgs: [parentId],
          );
          for (final child in childFolders) {
            final childId = child['id'] as String;
            final childName = validateFolderName(child['name'] as String);
            final childUri = await storage.findChildUri(
              parentUri: parentUri,
              name: childName,
            );
            folderUriUpdates[childId] = childUri;
            pendingFolders.add((childId, childUri));
          }
          final docs = await db.query(
            'documents',
            columns: ['id', 'name'],
            where: 'folder_id = ?',
            whereArgs: [parentId],
          );
          for (final doc in docs) {
            final documentName = '${doc['name'] as String}.pdf';
            documentUriUpdates[doc['id'] as String] = await storage.findChildUri(
              parentUri: parentUri,
              name: documentName,
            );
          }
        }
      } else {
        // App-private folders have no provider URI. Rename the actual private
        // directory and update every descendant document reference atomically.
        final base = await getApplicationDocumentsDirectory();
        final privateRoot = p.join(base.path, 'DocsGrid', 'PDFs');

        Future<List<String>> pathSegments({required bool useNewName}) async {
          final segments = <String>[];
          final seen = <String>{};
          String? currentId = id;
          while (currentId != null) {
            if (!seen.add(currentId)) {
              throw StateError('Folder hierarchy contains a cycle.');
            }
            final folderRows = await db.query(
              'folders',
              columns: ['name', 'parent_id'],
              where: 'id = ? AND deleted_at IS NULL',
              whereArgs: [currentId],
              limit: 1,
            );
            if (folderRows.isEmpty) {
              throw StateError('Folder hierarchy contains a missing parent.');
            }
            final rawName = currentId == id && useNewName
                ? cleaned
                : folderRows.first['name'] as String;
            segments.add(validateFolderName(rawName));
            currentId = folderRows.first['parent_id'] as String?;
          }
          return segments.reversed.toList();
        }

        final oldSegments = await pathSegments(useNewName: false);
        final newSegments = await pathSegments(useNewName: true);
        final oldPath = p.joinAll([privateRoot, ...oldSegments]);
        final newPath = p.joinAll([privateRoot, ...newSegments]);
        oldPrivatePath = oldPath;
        final oldDirectory = Directory(oldPath);
        if (await oldDirectory.exists()) {
          final newDirectory = Directory(newPath);
          if (await newDirectory.exists()) {
            throw StateError(
              'A private storage folder with the new name already exists. '
              'Resolve that folder before renaming to avoid merging documents.',
            );
          }
          await newDirectory.parent.create(recursive: true);
          renamedPrivateDirectory = await oldDirectory.rename(newDirectory.path);

          final pendingPrivateFolders = <String>[id];
          final visitedPrivateFolders = <String>{};
          while (pendingPrivateFolders.isNotEmpty) {
            final folderId = pendingPrivateFolders.removeLast();
            if (!visitedPrivateFolders.add(folderId)) {
              throw StateError('Folder hierarchy contains a cycle.');
            }
            final documents = await db.query(
              'documents',
              columns: ['id', 'storage_uri'],
              where: 'folder_id = ?',
              whereArgs: [folderId],
            );
            for (final document in documents) {
              final uri = document['storage_uri'] as String?;
              if (uri == null) continue;
              final updatedUri = remapPrivateDocumentPath(
                oldFolderPath: oldPath,
                newFolderPath: newPath,
                documentUri: uri,
              );
              if (updatedUri == null) continue;
              privateDocumentUpdates[document['id'] as String] = {
                'storage_uri': updatedUri,
                'relative_path': p.relative(updatedUri, from: privateRoot),
              };
            }
            final children = await db.query(
              'folders',
              columns: ['id'],
              where: 'parent_id = ? AND deleted_at IS NULL',
              whereArgs: [folderId],
            );
            pendingPrivateFolders.addAll(children.map((child) => child['id'] as String));
          }
        }
      }

      await db.transaction((txn) async {
        final siblings = await txn.query(
          'folders',
          columns: ['id'],
          where: 'parent_id IS ? AND name = ? COLLATE NOCASE AND deleted_at IS NULL AND id != ?',
          whereArgs: [rows.first['parent_id'], cleaned, id],
          limit: 1,
        );
        if (siblings.isNotEmpty) {
          throw StateError('A folder with this name already exists here.');
        }
        final now = DateTime.now().toUtc().toIso8601String();
        final count = await txn.update(
          'folders',
          {
            'name': cleaned,
            'storage_uri_or_relative_path': renamedUri,
            'updated_at': now,
          },
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [id],
        );
        if (count == 0) throw StateError('Folder no longer exists.');
        for (final entry in folderUriUpdates.entries) {
          await txn.update(
            'folders',
            {'storage_uri_or_relative_path': entry.value, 'updated_at': now},
            where: 'id = ? AND deleted_at IS NULL',
            whereArgs: [entry.key],
          );
        }
        for (final entry in documentUriUpdates.entries) {
          await txn.update(
            'documents',
            {'storage_uri': entry.value, 'updated_at': now},
            where: 'id = ?',
            whereArgs: [entry.key],
          );
        }
        for (final entry in privateDocumentUpdates.entries) {
          await txn.update(
            'documents',
            {...entry.value, 'updated_at': now},
            where: 'id = ?',
            whereArgs: [entry.key],
          );
        }
      });
      PortableSnapshotEvents.notifyDataChanged();
    } catch (_) {
      if (renamedUri != null) {
        try {
          await storage.renamePdf(uri: renamedUri, name: oldName);
        } catch (_) {
          // Preserve the original references; report the operation failure.
        }
      }
      if (renamedPrivateDirectory != null && oldPrivatePath != null) {
        try {
          await Directory(oldPrivatePath).parent.create(recursive: true);
          await renamedPrivateDirectory.rename(oldPrivatePath);
        } catch (_) {
          // Do not delete either copy if a rollback rename cannot complete.
        }
      }
      rethrow;
    }
  }

  /// Reparents selected folders as logical library folders. Stable storage
  /// URIs and documents are preserved; only the Grid hierarchy changes.
  /// If both a parent and child are selected, only the parent is reparented.
  Future<void> moveManyToParent(List<String> folderIds, String? parentId) async {
    await StorageMigrationGate.waitUntilReady();
    final requested = folderIds.toSet();
    if (requested.isEmpty) return;
    final db = await _database.database;
    await db.transaction((txn) async {
      final placeholders = List.filled(requested.length, '?').join(',');
      final rows = await txn.query(
        'folders',
        columns: ['id', 'name', 'parent_id'],
        where: 'id IN ($placeholders) AND deleted_at IS NULL',
        whereArgs: requested.toList(),
      );
      if (rows.length != requested.length) {
        throw StateError('One or more selected folders no longer exist.');
      }
      if (parentId != null) {
        final target = await txn.query(
          'folders',
          columns: ['id'],
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [parentId],
          limit: 1,
        );
        if (target.isEmpty) throw StateError('Destination folder no longer exists.');
      }
      final roots = rows.where((row) => !requested.contains(row['parent_id'] as String?)).toList();
      final rootIds = roots.map((row) => row['id'] as String).toSet();
      var ancestorId = parentId;
      final visited = <String>{};
      while (ancestorId != null) {
        if (!visited.add(ancestorId)) throw StateError('Folder hierarchy contains a cycle.');
        if (rootIds.contains(ancestorId)) {
          throw StateError('A folder cannot be moved inside itself or one of its subfolders.');
        }
        final parentRows = await txn.query(
          'folders',
          columns: ['parent_id'],
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [ancestorId],
          limit: 1,
        );
        if (parentRows.isEmpty) throw StateError('Destination folder no longer exists.');
        ancestorId = parentRows.first['parent_id'] as String?;
      }
      final movingNames = <String>{};
      for (final row in roots) {
        final name = (row['name'] as String).toLowerCase();
        if (!movingNames.add(name)) {
          throw StateError('Two selected folders have the same name and cannot share one destination.');
        }
        final duplicate = await txn.query(
          'folders',
          columns: ['id'],
          where: 'parent_id IS ? AND name = ? COLLATE NOCASE AND deleted_at IS NULL AND id != ?',
          whereArgs: [parentId, row['name'], row['id']],
          limit: 1,
        );
        if (duplicate.isNotEmpty) {
          throw StateError('A folder named "${row['name']}" already exists at the destination.');
        }
      }
      final maxRows = await txn.rawQuery(
        parentId == null
            ? 'SELECT COALESCE(MAX(sort_order), -1) AS max_order FROM folders WHERE parent_id IS NULL AND deleted_at IS NULL'
            : 'SELECT COALESCE(MAX(sort_order), -1) AS max_order FROM folders WHERE parent_id = ? AND deleted_at IS NULL',
        parentId == null ? null : [parentId],
      );
      var nextOrder = ((maxRows.first['max_order'] as int?) ?? -1) + 1;
      final batch = txn.batch();
      for (final row in roots) {
        batch.update(
          'folders',
          {
            'parent_id': parentId,
            'sort_order': nextOrder++,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          },
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [row['id']],
        );
      }
      await batch.commit(noResult: true);
    });
    PortableSnapshotEvents.notifyDataChanged();
  }

  /// Soft-deletes selected folders and all descendants. PDFs go to Recycle Bin
  /// with their folder_id cleared, so restoring them returns them to Grid root.
  /// Physical files are retained; this operation never permanently deletes PDFs.
  /// Soft-deletes selected roots as independent trash operations. Descendants,
  /// original parent IDs and document folder IDs are retained for full restore.
  Future<int> moveManyToRecycleBin(List<String> folderIds) async {
    await StorageMigrationGate.waitUntilReady();
    final requested = folderIds.toSet();
    if (requested.isEmpty) return 0;
    final db = await _database.database;
    var movedPdfCount = 0;
    await db.transaction((txn) async {
      final placeholders = List.filled(requested.length, '?').join(',');
      final selected = await txn.query(
        'folders',
        columns: ['id', 'parent_id'],
        where: 'id IN ($placeholders) AND deleted_at IS NULL',
        whereArgs: requested.toList(),
      );
      if (selected.length != requested.length) {
        throw StateError('One or more selected folders no longer exist.');
      }
      // If both parent and child were selected, only the parent becomes a root.
      final roots = selected.where((row) =>
        !requested.contains(row['parent_id'] as String?)).toList();
      for (final root in roots) {
        final operationId = _uuid.v4();
        final allIds = <String>{root['id'] as String};
        var frontier = <String>[root['id'] as String];
        while (frontier.isNotEmpty) {
          final childPlaceholders = List.filled(frontier.length, '?').join(',');
          final children = await txn.query(
            'folders',
            columns: ['id'],
            where: 'parent_id IN ($childPlaceholders) AND deleted_at IS NULL',
            whereArgs: frontier,
          );
          frontier = children.map((row) => row['id'] as String)
              .where(allIds.add).toList();
        }
        final allPlaceholders = List.filled(allIds.length, '?').join(',');
        final activeDocuments = await txn.query(
          'documents',
          columns: ['id'],
          where: 'folder_id IN ($allPlaceholders) AND deleted_at IS NULL',
          whereArgs: allIds.toList(),
        );
        final now = DateTime.now().toUtc().toIso8601String();
        movedPdfCount += activeDocuments.length;
        for (final document in activeDocuments) {
          await txn.insert('history', {
            'id': _uuid.v4(),
            'document_id': document['id'],
            'action': 'moved_to_recycle_bin',
            'details_json': jsonEncode({
              'folderDeleted': true,
              'trashOperationId': operationId,
            }),
            'created_at': now,
          });
        }
        await txn.update(
          'documents',
          {'deleted_at': now, 'updated_at': now, 'trash_operation_id': operationId},
          where: 'folder_id IN ($allPlaceholders) AND deleted_at IS NULL',
          whereArgs: allIds.toList(),
        );
        await txn.update(
          'folders',
          {'deleted_at': now, 'updated_at': now, 'trash_operation_id': operationId},
          where: 'id IN ($allPlaceholders) AND deleted_at IS NULL',
          whereArgs: allIds.toList(),
        );
      }
    });
    PortableSnapshotEvents.notifyDataChanged();
    return movedPdfCount;
  }

  Future<void> _backfillLegacyFolderTrashOperations() async {
    final db = await _database.database;
    final rows = await db.query(
      'folders',
      columns: ['id', 'parent_id', 'deleted_at'],
      where: 'deleted_at IS NOT NULL AND trash_operation_id IS NULL',
    );
    if (rows.isEmpty) return;
    final byId = <String, Map<String, Object?>>{
      for (final row in rows) row['id'] as String: row,
    };
    await db.transaction((txn) async {
      for (final row in rows) {
        final id = row['id'] as String;
        final deletedAt = row['deleted_at'] as String;
        var rootId = id;
        var parentId = row['parent_id'] as String?;
        final visited = <String>{id};
        while (parentId != null && visited.add(parentId)) {
          final parent = byId[parentId];
          if (parent == null || parent['deleted_at'] != deletedAt) break;
          rootId = parentId;
          parentId = parent['parent_id'] as String?;
        }
        await txn.update(
          'folders',
          {'trash_operation_id': 'legacy-folder-tree:$rootId'},
          where: 'id = ? AND deleted_at IS NOT NULL AND trash_operation_id IS NULL',
          whereArgs: [id],
        );
      }
    });
    PortableSnapshotEvents.notifyDataChanged();
  }

  /// Returns one visible root per DocsGrid folder-trash operation.
  Future<List<Map<String, Object?>>> listTrashFolderRoots() async {
    await _backfillLegacyFolderTrashOperations();
    final db = await _database.database;
    final roots = await db.rawQuery('''
      SELECT f.* FROM folders f
      WHERE f.deleted_at IS NOT NULL
        AND f.trash_operation_id IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM folders parent
          WHERE parent.id = f.parent_id
            AND parent.trash_operation_id = f.trash_operation_id
        )
      ORDER BY f.deleted_at DESC, f.name COLLATE NOCASE ASC
    ''');
    final result = <Map<String, Object?>>[];
    for (final row in roots) {
      final operationId = row['trash_operation_id'] as String;
      final folderCount = Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM folders WHERE trash_operation_id = ?',
        [operationId],
      )) ?? 1;
      final pdfCount = Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM documents WHERE trash_operation_id = ?',
        [operationId],
      )) ?? 0;
      result.add({...row, 'folder_count': folderCount, 'pdf_count': pdfCount});
    }
    return result;
  }

  /// Returns the hierarchy and PDFs represented by one Recycle Bin folder entry.
  Future<Map<String, Object?>> trashFolderContents(String rootFolderId) async {
    await _backfillLegacyFolderTrashOperations();
    final db = await _database.database;
    final rootRows = await db.query(
      'folders',
      columns: ['name', 'trash_operation_id'],
      where: 'id = ? AND deleted_at IS NOT NULL AND trash_operation_id IS NOT NULL',
      whereArgs: [rootFolderId],
      limit: 1,
    );
    if (rootRows.isEmpty) throw StateError('Folder is no longer in the Recycle Bin.');
    final operationId = rootRows.single['trash_operation_id'] as String;
    final folders = await db.query(
      'folders',
      columns: ['id', 'name', 'parent_id'],
      where: 'trash_operation_id = ? AND deleted_at IS NOT NULL',
      whereArgs: [operationId],
      orderBy: 'name COLLATE NOCASE ASC',
    );
    final names = <String, String>{
      for (final row in folders) row['id'] as String: row['name'] as String,
    };
    String pathFor(Map<String, Object?> row) {
      final parts = <String>[row['name'] as String];
      var parentId = row['parent_id'] as String?;
      final seen = <String>{row['id'] as String};
      while (parentId != null && names.containsKey(parentId)) {
        if (!seen.add(parentId)) break;
        parts.insert(0, names[parentId]!);
        final parent = folders.firstWhere((item) => item['id'] == parentId);
        parentId = parent['parent_id'] as String?;
      }
      return parts.join(' / ');
    }
    final documents = await db.query(
      'documents',
      columns: ['id', 'name', 'size_bytes', 'folder_id'],
      where: 'trash_operation_id = ? AND deleted_at IS NOT NULL',
      whereArgs: [operationId],
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return {
      'rootName': rootRows.single['name'],
      'folders': folders.map((row) => <String, Object?>{
        'id': row['id'],
        'name': row['name'],
        'path': pathFor(row),
      }).toList(growable: false),
      'documents': documents,
      'folderCount': folders.length,
      'pdfCount': documents.length,
    };
  }

  /// Restores exactly one folder operation. Separately deleted PDFs are excluded.
  Future<int> restoreTrashFolderTree(String rootFolderId) async {
    await StorageMigrationGate.waitUntilReady();
    final db = await _database.database;
    final roots = await db.query(
      'folders',
      columns: ['parent_id', 'trash_operation_id'],
      where: 'id = ? AND deleted_at IS NOT NULL AND trash_operation_id IS NOT NULL',
      whereArgs: [rootFolderId],
      limit: 1,
    );
    if (roots.isEmpty) throw StateError('Folder is no longer in the Recycle Bin.');
    final operationId = roots.single['trash_operation_id'] as String;
    final parentId = roots.single['parent_id'] as String?;
    if (parentId != null) {
      final parent = await db.query(
        'folders', columns: ['id'],
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [parentId], limit: 1,
      );
      if (parent.isEmpty) {
        throw StateError('Restore the parent folder first; its original location is still in the Recycle Bin.');
      }
    }
    final storage = StorageLocationService.instance;
    final folderRows = await db.query(
      'folders',
      columns: ['id', 'storage_uri_or_relative_path'],
      where: 'trash_operation_id = ? AND deleted_at IS NOT NULL',
      whereArgs: [operationId],
    );
    for (final folder in folderRows) {
      final uri = (folder['storage_uri_or_relative_path'] as String?)?.trim() ?? '';
      if (uri.isEmpty) continue;
      final children = await _listTrashDirectoryChildren(uri);
      if (children == null) {
        throw StateError('A folder in this deleted tree is missing. Repair storage access before restoring.');
      }
    }
    final documents = await db.query(
      'documents',
      columns: ['id', 'storage_uri', 'sha256'],
      where: 'trash_operation_id = ? AND deleted_at IS NOT NULL',
      whereArgs: [operationId],
    );
    // Verify reachability/content before changing folder or document state.
    for (final row in documents) {
      final uri = (row['storage_uri'] as String?)?.trim() ?? '';
      if (uri.isEmpty) throw StateError('A PDF in this folder has no storage location.');
      if (uri.startsWith('content://') || uri.startsWith('file://')) {
        final actual = await storage.sha256Pdf(uri);
        final expected = (row['sha256'] as String?) ?? '';
        if (expected.isNotEmpty && actual != expected) {
          throw StateError('A PDF in this folder failed SHA-256 verification. No records were restored.');
        }
      } else if (!await File(uri).exists()) {
        throw StateError('A PDF in this folder is missing: ${p.basename(uri)}');
      }
    }
    var restoredPdfs = 0;
    await db.transaction((txn) async {
      final folderCount = await txn.update(
        'folders',
        {'deleted_at': null, 'trash_operation_id': null,
         'updated_at': DateTime.now().toUtc().toIso8601String()},
        where: 'trash_operation_id = ? AND deleted_at IS NOT NULL',
        whereArgs: [operationId],
      );
      if (folderCount == 0) throw StateError('Folder trash operation is empty.');
      restoredPdfs = await txn.update(
        'documents',
        {'deleted_at': null, 'trash_operation_id': null,
         'updated_at': DateTime.now().toUtc().toIso8601String()},
        where: 'trash_operation_id = ? AND deleted_at IS NOT NULL',
        whereArgs: [operationId],
      );
      await txn.insert('history', {
        'id': _uuid.v4(), 'document_id': null,
        'action': 'folder_tree_restored',
        'details_json': jsonEncode({
          'rootFolderId': rootFolderId,
          'trashOperationId': operationId,
          'restoredPdfCount': restoredPdfs,
        }),
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
    PortableSnapshotEvents.notifyDataChanged();
    return restoredPdfs;
  }

  /// Returns null for a missing local/provider directory and an empty list for
  /// an existing empty folder. Provider access errors other than NOT_FOUND fail.
  Future<List<Map<String, Object?>>?> _listTrashDirectoryChildren(String uri) async {
    final storage = StorageLocationService.instance;
    if (uri.startsWith('content://')) {
      try {
        return await storage.listDirectory(uri);
      } on PlatformException catch (error) {
        if (StorageLocationService.isNotFoundError(error)) return null;
        rethrow;
      }
    }
    final path = uri.startsWith('file://') ? Uri.parse(uri).toFilePath() : uri;
    final directory = Directory(path);
    if (!await directory.exists()) return null;
    final children = <Map<String, Object?>>[];
    await for (final entity in directory.list(followLinks: false)) {
      children.add({
        'name': p.basename(entity.path),
        'uri': Uri.file(entity.path).toString(),
        'isDirectory': entity is Directory,
      });
    }
    return children;
  }

  Future<void> _deleteTrashItemIfExists(String uri) async {
    final storage = StorageLocationService.instance;
    if (uri.startsWith('content://')) {
      try {
        await storage.deletePdf(uri);
      } on PlatformException catch (error) {
        if (!StorageLocationService.isNotFoundError(error)) rethrow;
      }
      return;
    }
    final path = uri.startsWith('file://') ? Uri.parse(uri).toFilePath() : uri;
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
      return;
    }
    final directory = Directory(path);
    if (await directory.exists()) await directory.delete();
  }

  /// Deletes only content owned by this trash operation. Any independently
  /// recycled or untracked content blocks directory removal.
  Future<void> permanentlyDeleteTrashFolderTree(String rootFolderId) async {
    await StorageMigrationGate.waitUntilReady();
    final db = await _database.database;
    final roots = await db.query(
      'folders', columns: ['trash_operation_id'],
      where: 'id = ? AND deleted_at IS NOT NULL AND trash_operation_id IS NOT NULL',
      whereArgs: [rootFolderId], limit: 1,
    );
    if (roots.isEmpty) throw StateError('Folder is no longer in the Recycle Bin.');
    final operationId = roots.single['trash_operation_id'] as String;
    final folders = await db.query(
      'folders', columns: ['id', 'parent_id', 'storage_uri_or_relative_path'],
      where: 'trash_operation_id = ? AND deleted_at IS NOT NULL',
      whereArgs: [operationId],
    );
    final ids = folders.map((row) => row['id'] as String).toSet();
    if (ids.isEmpty) throw StateError('Folder trash operation is empty.');
    final placeholders = List.filled(ids.length, '?').join(',');
    final otherReferences = await db.query(
      'documents', columns: ['id'],
      where: 'folder_id IN ($placeholders) AND COALESCE(trash_operation_id, '') != ?',
      whereArgs: [...ids, operationId], limit: 1,
    );
    if (otherReferences.isNotEmpty) {
      throw StateError('This folder contains a separately recycled PDF. Permanently delete or restore that PDF first.');
    }
    final documents = await db.query(
      'documents', columns: ['id', 'name', 'storage_uri'],
      where: 'trash_operation_id = ? AND deleted_at IS NOT NULL',
      whereArgs: [operationId],
    );
    final knownUris = <String>{
      ...documents.map((row) => (row['storage_uri'] as String?) ?? ''),
      ...folders.map((row) => (row['storage_uri_or_relative_path'] as String?) ?? ''),
    };
    // Preflight every physical folder before deleting any PDF.
    for (final folder in folders) {
      final uri = folder['storage_uri_or_relative_path'] as String?;
      if (uri == null || uri.isEmpty) continue;
      final children = (await _listTrashDirectoryChildren(uri)) ?? const <Map<String, Object?>>[];
      for (final child in children) {
        final childUri = child['uri'] as String? ?? '';
        if (childUri.isNotEmpty && !knownUris.contains(childUri)) {
          throw StateError('Folder contains an untracked item and was kept safe: ${child['name'] ?? ''}');
        }
      }
    }
    for (final document in documents) {
      final uri = (document['storage_uri'] as String?)?.trim() ?? '';
      if (uri.isEmpty) throw StateError('A recycled PDF has no storage location.');
      await _deleteTrashItemIfExists(uri);
      await db.transaction((txn) async {
        await txn.delete('reminders', where: 'document_id = ?', whereArgs: [document['id']]);
        await txn.delete('documents', where: 'id = ?', whereArgs: [document['id']]);
        await txn.insert('history', {
          'id': _uuid.v4(), 'document_id': null,
          'action': 'folder_trash_pdf_permanently_deleted',
          'details_json': jsonEncode({
            'documentId': document['id'], 'name': document['name'],
            'trashOperationId': operationId,
          }),
          'created_at': DateTime.now().toUtc().toIso8601String(),
        });
      });
    }
    final byId = {for (final row in folders) row['id'] as String: row};
    int depth(Map<String, Object?> row) {
      var count = 0;
      var parentId = row['parent_id'] as String?;
      final seen = <String>{};
      while (parentId != null && byId.containsKey(parentId)) {
        if (!seen.add(parentId)) throw StateError('Folder hierarchy contains a cycle.');
        count++;
        parentId = byId[parentId]!['parent_id'] as String?;
      }
      return count;
    }
    final deepestFirst = [...folders]..sort((a, b) => depth(b).compareTo(depth(a)));
    for (final folder in deepestFirst) {
      final uri = folder['storage_uri_or_relative_path'] as String?;
      if (uri != null && uri.isNotEmpty) {
        final children = (await _listTrashDirectoryChildren(uri)) ?? const <Map<String, Object?>>[];
        if (children.isNotEmpty) {
          throw StateError('Folder still contains files or subfolders and was retained: ${folder['id']}');
        }
        await _deleteTrashItemIfExists(uri);
      }
    }
    await db.transaction((txn) async {
      await txn.delete('folders',
        where: 'trash_operation_id = ? AND deleted_at IS NOT NULL',
        whereArgs: [operationId]);
      await txn.insert('history', {
        'id': _uuid.v4(), 'document_id': null,
        'action': 'folder_tree_permanently_deleted',
        'details_json': jsonEncode({'rootFolderId': rootFolderId, 'trashOperationId': operationId}),
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
    PortableSnapshotEvents.notifyDataChanged();
  }

  /// Empty folders are sent to Grid Recycle Bin; their physical directory
  /// remains until the user explicitly empties the bin.
  Future<void> deleteEmpty(String id) async {
    await StorageMigrationGate.waitUntilReady();
    final db = await _database.database;
    final folder = await db.query(
      'folders', columns: ['id', 'storage_uri_or_relative_path'],
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [id], limit: 1,
    );
    if (folder.isEmpty) throw StateError('Folder no longer exists.');
    final childFolders = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM folders WHERE parent_id = ? AND deleted_at IS NULL', [id],
    )) ?? 0;
    final documents = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM documents WHERE folder_id = ?', [id],
    )) ?? 0;
    if (childFolders > 0 || documents > 0) {
      throw StateError('Folder is not empty. Move its contents before deleting it.');
    }
    final storageUri = folder.single['storage_uri_or_relative_path'] as String?;
    if (storageUri != null &&
        (storageUri.startsWith('content://') || storageUri.startsWith('file://'))) {
      final physicalChildren = await StorageLocationService.instance.listDirectory(storageUri);
      if (physicalChildren.isNotEmpty) {
        throw StateError('This folder contains untracked items. Move or remove them before deleting it.');
      }
    }
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      final count = await txn.update('folders', {
        'deleted_at': now,
        'updated_at': now,
        'trash_operation_id': _uuid.v4(),
      }, where: 'id = ? AND deleted_at IS NULL', whereArgs: [id]);
      if (count == 0) throw StateError('Folder no longer exists.');
    });
    PortableSnapshotEvents.notifyDataChanged();
  }

}
