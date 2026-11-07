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
    Future<void> visit(String? parentId, String prefix) async {
      final children = await childrenOf(parentId);
      for (final folder in children) {
        final path = prefix.isEmpty ? folder.name : '$prefix / ${folder.name}';
        result.add(FolderOption(folder: folder, path: path));
        await visit(folder.id, path);
      }
    }
    await visit(null, '');
    return result;
  }

  Future<Folder> create({required String name, String? parentId}) async {
    final cleaned = name.trim();
    if (cleaned.isEmpty) throw ArgumentError('Folder name cannot be empty.');
    if (cleaned.contains('/') || cleaned.contains('\\')) {
      throw ArgumentError('Folder name cannot contain / or \\.');
    }
    final db = await _database.database;
    final storage = StorageLocationService.instance;
    final selectedRoot = await storage.selectedFolder();
    Future<String?> ensurePhysicalFolder(String folderId) async {
      final rows = await db.query(
        'folders',
        columns: ['name', 'parent_id', 'storage_uri_or_relative_path'],
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [folderId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Parent folder no longer exists.');
      final row = rows.first;
      final existingUri = row['storage_uri_or_relative_path'] as String?;
      if (existingUri != null) return existingUri;
      final ancestorId = row['parent_id'] as String?;
      final ancestorUri = ancestorId == null
          ? selectedRoot?['uri']
          : await ensurePhysicalFolder(ancestorId);
      if (ancestorUri == null) return null;
      final createdUri = await storage.createDirectory(
        parentUri: ancestorUri,
        name: row['name'] as String,
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
        ? selectedRoot?['uri']
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
    final cleaned = name.trim();
    if (cleaned.isEmpty) throw ArgumentError('Folder name cannot be empty.');
    if (cleaned.contains('/') || cleaned.contains('\\')) {
      throw ArgumentError('Folder name cannot contain / or \\.');
    }
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
    final oldUri = rows.first['storage_uri_or_relative_path'] as String?;
    final storage = StorageLocationService.instance;
    final renamedUri = oldUri == null
        ? null
        : await storage.renamePdf(uri: oldUri, name: cleaned);

    final folderUriUpdates = <String, String>{};
    final documentUriUpdates = <String, String>{};
    try {
      if (renamedUri != null) {
      Future<void> collectDescendants(String parentId, String parentUri) async {
        final childFolders = await db.query(
          'folders',
          columns: ['id', 'name'],
          where: 'parent_id = ? AND deleted_at IS NULL',
          whereArgs: [parentId],
        );
        for (final child in childFolders) {
          final childId = child['id'] as String;
          final childName = child['name'] as String;
          final childUri = await storage.findChildUri(parentUri: parentUri, name: childName);
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
          final documentName = '${doc['name'] as String}.pdf';
          documentUriUpdates[doc['id'] as String] = await storage.findChildUri(
            parentUri: parentUri,
            name: documentName,
          );
        }
      }

      await collectDescendants(id, renamedUri);
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
      });
    } catch (_) {
      if (renamedUri != null) {
        try {
          await storage.renamePdf(uri: renamedUri, name: oldName);
        } catch (_) {
          // Keep the failure visible; the old database references remain intact.
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
}}
