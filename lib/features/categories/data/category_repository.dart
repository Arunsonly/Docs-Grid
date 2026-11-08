import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';

class CategoryRecord {
  const CategoryRecord({
    required this.id,
    required this.name,
    required this.isBuiltIn,
  });

  final String id;
  final String name;
  final bool isBuiltIn;

  factory CategoryRecord.fromMap(Map<String, Object?> row) => CategoryRecord(
        id: row['id'] as String,
        name: row['name'] as String,
        isBuiltIn: (row['is_builtin'] as int? ?? 0) == 1,
      );
}

class TagRecord {
  const TagRecord({required this.id, required this.name});

  final String id;
  final String name;

  factory TagRecord.fromMap(Map<String, Object?> row) =>
      TagRecord(id: row['id'] as String, name: row['name'] as String);
}

class CategoryRepository {
  CategoryRepository({AppDatabase? database})
      : _database = database ?? AppDatabase.instance;

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<List<CategoryRecord>> listCategories() async {
    final db = await _database.database;
    final rows = await db.query('categories', orderBy: 'name COLLATE NOCASE');
    return rows.map(CategoryRecord.fromMap).toList();
  }

  Future<CategoryRecord> createCategory(String name) async {
    final cleaned = validateName(name);
    final db = await _database.database;
    final category = CategoryRecord(id: _uuid.v4(), name: cleaned, isBuiltIn: false);
    await db.insert('categories', {
      'id': category.id,
      'name': category.name,
      'is_builtin': 0,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    return category;
  }

  Future<void> renameCategory(CategoryRecord category, String name) async {
    if (category.isBuiltIn) {
      throw StateError('Built-in categories cannot be renamed.');
    }
    final db = await _database.database;
    final count = await db.update(
      'categories',
      {'name': validateName(name)},
      where: 'id = ? AND is_builtin = 0',
      whereArgs: [category.id],
    );
    if (count == 0) throw StateError('Category no longer exists.');
  }

  Future<void> deleteCategory(CategoryRecord category) async {
    if (category.isBuiltIn) {
      throw StateError('Built-in categories cannot be deleted.');
    }
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.update('documents', {'category_id': null},
          where: 'category_id = ?', whereArgs: [category.id]);
      await txn.delete('categories', where: 'id = ?', whereArgs: [category.id]);
    });
  }

  Future<List<TagRecord>> listTags() async {
    final db = await _database.database;
    final rows = await db.query('tags', orderBy: 'name COLLATE NOCASE');
    return rows.map(TagRecord.fromMap).toList();
  }

  Future<TagRecord> createTag(String name) async {
    final cleaned = validateName(name);
    final db = await _database.database;
    final tag = TagRecord(id: _uuid.v4(), name: cleaned);
    await db.insert('tags', {
      'id': tag.id,
      'name': tag.name,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
    return tag;
  }

  Future<void> renameTag(TagRecord tag, String name) async {
    final db = await _database.database;
    final count = await db.update(
      'tags',
      {'name': validateName(name)},
      where: 'id = ?',
      whereArgs: [tag.id],
    );
    if (count == 0) throw StateError('Tag no longer exists.');
  }

  Future<void> deleteTag(TagRecord tag) async {
    final db = await _database.database;
    await db.delete('tags', where: 'id = ?', whereArgs: [tag.id]);
  }

  Future<List<TagRecord>> tagsForDocument(String documentId) async {
    final db = await _database.database;
    final rows = await db.rawQuery('''
      SELECT t.id, t.name FROM tags t
      INNER JOIN document_tags dt ON dt.tag_id = t.id
      WHERE dt.document_id = ? ORDER BY t.name COLLATE NOCASE
    ''', [documentId]);
    return rows.map(TagRecord.fromMap).toList();
  }

  Future<void> setDocumentTags(String documentId, List<String> tagIds) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.delete('document_tags', where: 'document_id = ?', whereArgs: [documentId]);
      for (final tagId in tagIds.toSet()) {
        await txn.insert('document_tags', {'document_id': documentId, 'tag_id': tagId},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }

  Future<void> setDocumentCategory(String documentId, String? categoryId) async {
    final db = await _database.database;
    await db.update('documents', {'category_id': categoryId,
      'updated_at': DateTime.now().toUtc().toIso8601String()},
      where: 'id = ? AND deleted_at IS NULL', whereArgs: [documentId]);
  }

  @visibleForTesting
  static String validateName(String name) {
    final cleaned = name.trim();
    if (cleaned.isEmpty) throw ArgumentError('Name cannot be empty.');
    if (cleaned.length > 40) throw ArgumentError('Name must be 40 characters or fewer.');
    return cleaned;
  }
}
