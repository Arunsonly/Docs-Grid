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
    String? parentStorageUri;
    if (parentId != null) {
      final parentRows = await db.query(
        'folders',
        columns: ['storage_uri_or_relative_path'],
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [parentId],
        limit: 1,
      );
      if (parentRows.isEmpty) throw StateError('Parent folder no longer exists.');
      parentStorageUri = parentRows.first['storage_uri_or_relative_path'] as String?;
    } else {
      parentStorageUri = selectedRoot?['uri'];
    }
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
      columns: ['storage_uri_or_relative_path'],
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Folder no longer exists.');
    final storageUri = rows.first['storage_uri_or_relative_path'] as String?;
    final renamedUri = storageUri == null
        ? null
        : await StorageLocationService.instance.renamePdf(uri: storageUri, name: cleaned);
    final count = await db.update(
      'folders',
      {
        'name': cleaned,
        'storage_uri_or_relative_path': renamedUri,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [id],
    );
    if (count == 0) throw StateError('Folder no longer exists.');
  }

  Future<void> deleteEmpty(String id) async {
    final db = await _database.database;
    final folder = await db.query('folders', where: 'id = ? AND deleted_at IS NULL', whereArgs: [id]);
    if (folder.isEmpty) throw StateError('Folder no longer exists.');
    final childFolders = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM folders WHERE parent_id = ? AND deleted_at IS NULL', [id],
    )) ?? 0;
    final documents = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM documents WHERE folder_id = ? AND deleted_at IS NULL', [id],
    )) ?? 0;
    if (childFolders > 0 || documents > 0) {
      throw StateError('Folder is not empty. Move its contents before deleting it.');
    }
    final storageUri = folder.first['storage_uri_or_relative_path'] as String?;
    if (storageUri != null) {
      await StorageLocationService.instance.deletePdf(storageUri);
    }
    await db.update('folders', {
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, where: 'id = ?', whereArgs: [id]);
  }
}
