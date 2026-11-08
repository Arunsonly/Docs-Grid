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

  /// Validates a single folder-name segment before it reaches either the
  /// database hierarchy or a platform storage provider.
  static String validateFolderName(String name) {
    final cleaned = name.trim();
    if (cleaned.isEmpty) throw ArgumentError('Folder name cannot be empty.');
    if (cleaned == '.' || cleaned == '..') {
      throw ArgumentError('Folder name cannot be . or ..');
    }
    if (cleaned.contains('/') || cleaned.contains('\\')) {
      throw ArgumentError('Folder name cannot contain path separators.');
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
    final db = await _database.database;
    final rows = await db.query(
      'folders',
      where: 'deleted_at IS NULL',
      orderBy: 'name COLLATE NOCASE ASC',
    );
    final folders = rows.map(Folder.fromMap).toList(growable: false);
    final childrenByParent = <String?, List<Folder>>{};
    for (final folder in folders) {
      childrenByParent.putIfAbsent(folder.parentId, () => <Folder>[]).add(folder);
    }

    final result = <FolderOption>[];
    final visited = <String>{};
    final stack = <({Folder folder, String prefix})>[];
    final roots = childrenByParent[null] ?? const <Folder>[];
    for (final folder in roots.reversed) {
      stack.add((folder: folder, prefix: ''));
    }
    while (stack.isNotEmpty) {
      final item = stack.removeLast();
      if (!visited.add(item.folder.id)) {
        throw StateError('Folder hierarchy contains a cycle or duplicate reference.');
      }
      final path = item.prefix.isEmpty
          ? item.folder.name
          : '${item.prefix} / ${item.folder.name}';
      result.add(FolderOption(folder: item.folder, path: path));
      final children = childrenByParent[item.folder.id] ?? const <Folder>[];
      for (final child in children.reversed) {
        stack.add((folder: child, prefix: path));
      }
    }
    if (visited.length != folders.length) {
      throw StateError('Folder hierarchy contains an unreachable cycle or orphan.');
    }
    return result;
  }

  /// Ensures a virtual folder and its ancestors exist in the selected
  /// physical storage tree. Returns null when the library is app-private.
  Future<String?> ensurePhysicalStorageUri(String folderId) async {
    final db = await _database.database;
    final selectedRoot = await StorageLocationService.instance.selectedFolder();
    if (selectedRoot == null) return null;

    final unresolved = <Map<String, Object?>>[];
    final visited = <String>{};
    String? current = folderId;
    String? parentUri;
    while (current != null) {
      if (!visited.add(current)) {
        throw StateError('Folder hierarchy contains a cycle.');
      }
      final rows = await db.query(
        'folders',
        columns: ['id', 'name', 'parent_id', 'storage_uri_or_relative_path'],
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [current],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Folder no longer exists.');
      final row = rows.first;
      final existingUri = row['storage_uri_or_relative_path'] as String?;
      if (existingUri != null) {
        parentUri = existingUri;
        break;
      }
      unresolved.add(row);
      current = row['parent_id'] as String?;
    }

    parentUri ??= selectedRoot['uri'];
    for (final row in unresolved.reversed) {
      if (parentUri == null) return null;
      final name = row['name'] as String;
      final existingUri = await StorageLocationService.instance.findChildUriIfExists(
        parentUri: parentUri,
        name: name,
      );
      final childUri = existingUri ?? await StorageLocationService.instance.createDirectory(
        parentUri: parentUri,
        name: name,
      );
      await db.update(
        'folders',
        {
          'storage_uri_or_relative_path': childUri,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [row['id']],
      );
      parentUri = childUri;
    }
    return parentUri;
  }

  Future<Folder> create({required String name, String? parentId}) async {
    final cleaned = name.trim();
    if (cleaned.isEmpty) throw ArgumentError('Folder name cannot be empty.');
    if (cleaned == '.' || cleaned == '..') {
      throw ArgumentError('Folder name cannot be . or ..');
    }
    if (cleaned.contains('/') || cleaned.contains('\\\\')) {
      throw ArgumentError('Folder name cannot contain path separators.');
    }
    final db = await _database.database;
    final storage = StorageLocationService.instance;
    final selectedRoot = await storage.selectedFolder();
    final parentStorageUri = parentId == null
        ? (selectedRoot == null ? null : selectedRoot['uri'])
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
    if (cleaned.contains('/') || cleaned.contains('\\\\')) {
      throw ArgumentError('Folder name cannot contain path separators.');
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
        final pending = <({String id, String uri})>[
          (id: parentId, uri: parentUri),
        ];
        final visited = <String>{};
        while (pending.isNotEmpty) {
          final current = pending.removeLast();
          if (!visited.add(current.id)) {
            throw StateError('Folder hierarchy contains a cycle.');
          }
          final childFolders = await db.query(
            'folders',
            columns: ['id', 'name'],
            where: 'parent_id = ? AND deleted_at IS NULL',
            whereArgs: [current.id],
          );
          for (final child in childFolders) {
            final childId = child['id'] as String;
            final childName = child['name'] as String;
            final childUri = await storage.findChildUri(
              parentUri: current.uri,
              name: childName,
            );
            folderUriUpdates[childId] = childUri;
            pending.add((id: childId, uri: childUri));
          }
          final docs = await db.query(
            'documents',
            columns: ['id', 'name'],
            where: 'folder_id = ?',
            whereArgs: [current.id],
          );
          for (final doc in docs) {
            final documentName = '${doc['name'] as String}.pdf';
            documentUriUpdates[doc['id'] as String] = await storage.findChildUri(
              parentUri: current.uri,
              name: documentName,
            );
          }
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
}
