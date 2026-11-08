import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/storage/storage_location_service.dart';
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
  static String validateFolderName(String name) {
    final cleaned = name.trim();
    if (cleaned.isEmpty) throw ArgumentError('Folder name cannot be empty.');
    if (cleaned == '.' || cleaned == '..') {
      throw ArgumentError('Folder name cannot be . or ..');
    }
    if (cleaned.contains('/') || cleaned.contains('\\')) {
      throw ArgumentError('Folder name cannot contain / or \\.');
    }
    return cleaned;
  }

  Future<List<Folder>> childrenOf(String? parentId) async {
    final db = await _database.database;
    final rows = await db.query(
      'folders',
      where: parentId == null ? 'parent_id IS NULL AND deleted_at IS NULL' : 'parent_id = ? AND deleted_at IS NULL',
      whereArgs: parentId == null ? null : [parentId],
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return rows.map(Folder.fromMap).toList();
  }

  Future<List<FolderOption>> allFoldersWithPaths() async {
    final result = <FolderOption>[];
    final visited = <String>{};
    Future<void> visit(String? parentId, String prefix) async {
      final children = await childrenOf(parentId);
      for (final folder in children) {
        if (!visited.add(folder.id)) {
          throw StateError('Folder hierarchy contains a cycle or duplicate reference.');
        }
        final path = prefix.isEmpty ? folder.name : '$prefix / ${folder.name}';
        result.add(FolderOption(folder: folder, path: path));
        await visit(folder.id, path);
      }
    }
    await visit(null, '');
    return result;
  }

  /// Ensures a virtual folder and its ancestors exist in the selected
  /// physical storage tree. Returns null when the library is app-private.
  Future<String?> ensurePhysicalStorageUri(String folderId) async {
    final db = await _database.database;
    final selectedRoot = await StorageLocationService.instance.selectedFolder();
    if (selectedRoot == null) return null;
    final resolving = <String>{};

    Future<String?> ensure(String id) async {
      if (!resolving.add(id)) {
        throw StateError('Folder hierarchy contains a cycle.');
      }
      final rows = await db.query(
        'folders',
        columns: ['name', 'parent_id', 'storage_uri_or_relative_path'],
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Folder no longer exists.');
      final row = rows.first;
      final folderName = validateFolderName(row['name'] as String);
      final currentUri = row['storage_uri_or_relative_path'] as String?;
      if (currentUri != null) return currentUri;
      final parentId = row['parent_id'] as String?;
      final parentUri = parentId == null ? selectedRoot['uri'] : await ensure(parentId);
      if (parentUri == null) return null;
      String childUri;
      try {
        childUri = await StorageLocationService.instance.findChildUri(
          parentUri: parentUri,
          name: folderName,
        );
      } catch (_) {
        childUri = await StorageLocationService.instance.createDirectory(
          parentUri: parentUri,
          name: folderName,
        );
      }
      await db.update(
        'folders',
        {
          'storage_uri_or_relative_path': childUri,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [id],
      );
      return childUri;
    }

    return ensure(folderId);
  }

  Future<Folder> create({required String name, String? parentId}) async {
    final cleaned = validateFolderName(name);
    final db = await _database.database;
    final storage = StorageLocationService.instance;
    final selectedRoot = await storage.selectedFolder();
    final resolvingParents = <String>{};
    Future<String?> ensurePhysicalFolder(String folderId) async {
      if (!resolvingParents.add(folderId)) {
        throw StateError('Parent folder hierarchy contains a cycle.');
      }
      final rows = await db.query(
        'folders',
        columns: ['name', 'parent_id', 'storage_uri_or_relative_path'],
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [folderId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Parent folder no longer exists.');
      final row = rows.first;
      final folderName = validateFolderName(row['name'] as String);
      final existingUri = row['storage_uri_or_relative_path'] as String?;
      if (existingUri != null) return existingUri;
      final ancestorId = row['parent_id'] as String?;
      final ancestorUri = ancestorId == null
          ? (selectedRoot == null ? null : selectedRoot['uri'])
          : await ensurePhysicalFolder(ancestorId);
      if (ancestorUri == null) return null;
      final createdUri = await storage.createDirectory(
        parentUri: ancestorUri,
        name: folderName,
      );
      await db.update(
        'folders',
        {
          'storage_uri_or_relative_path': createdUri,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [folderId],
      );
      return createdUri;
    }

    final parentStorageUri = parentId == null
        ? (selectedRoot == null ? null : selectedRoot['uri'])
        : await ensurePhysicalFolder(parentId);
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
      await db.insert('folders', {
        'id': folder.id,
        'name': folder.name,
        'parent_id': folder.parentId,
        'storage_uri_or_relative_path': physicalUri,
        'created_at': now,
        'updated_at': now,
      });
    } catch (_) {
      if (physicalUri != null) {
        try { await storage.deletePdf(physicalUri); } catch (_) {}
      }
      rethrow;
    }
    return folder;
  }

  Future<void> rename(String id, String name) async {
    final cleaned = validateFolderName(name);
    final db = await _database.database;
    final rows = await db.query(
      'folders',
      columns: ['name', 'storage_uri_or_relative_path'],
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
    String? newPrivatePath;
    String? privateRootPath;

    try {
      if (renamedUri != null) {
        Future<void> collectDescendants(String parentId, String parentUri) async {
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
            await collectDescendants(childId, childUri);
          }
          final docs = await db.query(
            'documents',
            columns: ['id', 'name'],
            where: 'folder_id = ?',
            whereArgs: [parentId],
          );
          for (final doc in docs) {
            final documentName = '\${doc['name'] as String}.pdf';
            documentUriUpdates[doc['id'] as String] = await storage.findChildUri(
              parentUri: parentUri,
              name: documentName,
            );
          }
        }

        await collectDescendants(id, renamedUri);
      } else {
        // App-private folders have no provider URI. Rename the actual private
        // directory and update every descendant document reference atomically.
        final base = await getApplicationDocumentsDirectory();
        final privateRoot = p.join(base.path, 'DocsGrid', 'PDFs');
        privateRootPath = privateRoot;

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
        newPrivatePath = newPath;
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

          Future<void> collectPrivateDocuments(
            String folderId,
            Set<String> visited,
          ) async {
            if (!visited.add(folderId)) {
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
              if (uri == null ||
                  uri.startsWith('content://') ||
                  uri.startsWith('file://') ||
                  !p.isWithin(oldPath, uri)) {
                continue;
              }
              final relative = p.relative(uri, from: oldPath);
              final updatedUri = p.join(newPath, relative);
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
            for (final child in children) {
              await collectPrivateDocuments(child['id'] as String, visited);
            }
          }

          await collectPrivateDocuments(id, <String>{});
        }
      }

      await db.transaction((txn) async {
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

  Future<void> deleteEmpty(String id) async {
    final db = await _database.database;
    final folder = await db.query(
      'folders',
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [id],
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
    final storageUri = folder.first['storage_uri_or_relative_path'] as String?;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      final count = await txn.update(
        'folders',
        {'deleted_at': now, 'updated_at': now},
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [id],
      );
      if (count == 0) throw StateError('Folder no longer exists.');
    });
    if (storageUri != null) {
      try {
        await StorageLocationService.instance.deletePdf(storageUri);
      } catch (_) {
        // Restore the visible DB record if the physical directory could not be deleted.
        await db.update(
          'folders',
          {'deleted_at': null, 'updated_at': DateTime.now().toUtc().toIso8601String()},
          where: 'id = ?',
          whereArgs: [id],
        );
        rethrow;
      }
    }
  }
}
