import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../domain/folder.dart';

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

  Future<Folder> create({required String name, String? parentId}) async {
    final cleaned = name.trim();
    if (cleaned.isEmpty) throw ArgumentError('Folder name cannot be empty.');
    if (cleaned.contains('/') || cleaned.contains('\\')) {
      throw ArgumentError('Folder name cannot contain / or \\.');
    }
    final db = await _database.database;
    final now = DateTime.now().toUtc().toIso8601String();
    final folder = Folder(
      id: _uuid.v4(),
      name: cleaned,
      parentId: parentId,
      createdAt: DateTime.parse(now),
      updatedAt: DateTime.parse(now),
    );
    await db.insert('folders', {
      'id': folder.id,
      'name': folder.name,
      'parent_id': folder.parentId,
      'created_at': now,
      'updated_at': now,
    });
    return folder;
  }

  Future<void> rename(String id, String name) async {
    final cleaned = name.trim();
    if (cleaned.isEmpty) throw ArgumentError('Folder name cannot be empty.');
    if (cleaned.contains('/') || cleaned.contains('\\')) {
      throw ArgumentError('Folder name cannot contain / or \\.');
    }
    final db = await _database.database;
    final count = await db.update(
      'folders',
      {'name': cleaned, 'updated_at': DateTime.now().toUtc().toIso8601String()},
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
    await db.update('folders', {
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, where: 'id = ?', whereArgs: [id]);
  }
}
