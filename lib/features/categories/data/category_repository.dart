import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/storage/portable_snapshot_events.dart';

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
    await db.transaction((txn) async {
      await txn.insert('categories', {
        'id': category.id,
        'name': category.name,
        'is_builtin': 0,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      await _recordHistory(txn, null, 'category_created', {'category_id': category.id, 'name': cleaned});
    });
    PortableSnapshotEvents.notifyDataChanged();
    return category;
  }

  Future<void> renameCategory(CategoryRecord category, String name) async {
    if (category.isBuiltIn) {
      throw StateError('Built-in categories cannot be renamed.');
    }
    final cleaned = validateName(name);
    final db = await _database.database;
    await db.transaction((txn) async {
      final count = await txn.update(
        'categories',
        {'name': cleaned},
        where: 'id = ? AND is_builtin = 0',
        whereArgs: [category.id],
      );
      if (count == 0) throw StateError('Category no longer exists.');
      await _recordHistory(txn, null, 'category_renamed', {
        'category_id': category.id, 'from': category.name, 'to': cleaned,
      });
    });
    PortableSnapshotEvents.notifyDataChanged();
  }

  Future<void> deleteCategory(CategoryRecord category) async {
    if (category.isBuiltIn) {
      throw StateError('Built-in categories cannot be deleted.');
    }
    final db = await _database.database;
    await db.transaction((txn) async {
      final current = await txn.query(
        'categories',
        columns: ['is_builtin'],
        where: 'id = ?',
        whereArgs: [category.id],
        limit: 1,
      );
      if (current.isEmpty || (current.first['is_builtin'] as int? ?? 0) == 1) {
        throw StateError('Category no longer exists or is built in.');
      }
      final affected = Sqflite.firstIntValue(await txn.rawQuery(
        'SELECT COUNT(*) FROM documents WHERE category_id = ?', [category.id],
      )) ?? 0;
      await txn.update(
        'documents',
        {'category_id': null},
        where: 'category_id = ?',
        whereArgs: [category.id],
      );
      final deleted = await txn.delete(
        'categories',
        where: 'id = ? AND is_builtin = 0',
        whereArgs: [category.id],
      );
      if (deleted == 0) throw StateError('Category changed during deletion.');
      await _recordHistory(txn, null, 'category_deleted', {
        'category_id': category.id, 'name': category.name, 'documents_affected': affected,
      });
    });
    PortableSnapshotEvents.notifyDataChanged();
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
    await db.transaction((txn) async {
      await txn.insert('tags', {
        'id': tag.id,
        'name': tag.name,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      await _recordHistory(txn, null, 'tag_created', {'tag_id': tag.id, 'name': cleaned});
    });
    PortableSnapshotEvents.notifyDataChanged();
    return tag;
  }

  Future<void> renameTag(TagRecord tag, String name) async {
    final db = await _database.database;
    final cleaned = validateName(name);
    await db.transaction((txn) async {
      final count = await txn.update(
        'tags',
        {'name': cleaned},
        where: 'id = ?',
        whereArgs: [tag.id],
      );
      if (count == 0) throw StateError('Tag no longer exists.');
      await _recordHistory(txn, null, 'tag_renamed', {
        'tag_id': tag.id, 'from': tag.name, 'to': cleaned,
      });
    });
    PortableSnapshotEvents.notifyDataChanged();
  }

  Future<void> deleteTag(TagRecord tag) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      final count = await txn.delete('tags', where: 'id = ?', whereArgs: [tag.id]);
      if (count == 0) throw StateError('Tag no longer exists.');
      await _recordHistory(txn, null, 'tag_deleted', {'tag_id': tag.id, 'name': tag.name});
    });
    PortableSnapshotEvents.notifyDataChanged();
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
      final documents = await txn.query(
        'documents',
        columns: ['id'],
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [documentId],
        limit: 1,
      );
      if (documents.isEmpty) throw StateError('Document no longer exists.');
      final beforeRows = await txn.rawQuery('''
        SELECT t.name FROM tags t
        INNER JOIN document_tags dt ON dt.tag_id = t.id
        WHERE dt.document_id = ? ORDER BY t.name COLLATE NOCASE
      ''', [documentId]);
      await txn.delete('document_tags', where: 'document_id = ?', whereArgs: [documentId]);
      for (final tagId in tagIds.toSet()) {
        await txn.insert(
          'document_tags',
          {'document_id': documentId, 'tag_id': tagId},
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      final afterRows = await txn.rawQuery('''
        SELECT t.name FROM tags t
        INNER JOIN document_tags dt ON dt.tag_id = t.id
        WHERE dt.document_id = ? ORDER BY t.name COLLATE NOCASE
      ''', [documentId]);
      final before = beforeRows.map((row) => row['name']).toList();
      final after = afterRows.map((row) => row['name']).toList();
      if (before.toString() != after.toString()) {
        await txn.update('documents',
          {'updated_at': DateTime.now().toUtc().toIso8601String()},
          where: 'id = ?', whereArgs: [documentId]);
        await _recordHistory(txn, documentId, 'tags_changed', {'from': before, 'to': after});
      }
    });
    PortableSnapshotEvents.notifyDataChanged();
  }

  Future<void> setDocumentCategory(String documentId, String? categoryId) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      final documents = await txn.query(
        'documents', columns: ['category_id'],
        where: 'id = ? AND deleted_at IS NULL', whereArgs: [documentId], limit: 1,
      );
      if (documents.isEmpty) throw StateError('Document no longer exists.');
      final oldCategoryId = documents.first['category_id'] as String?;
      if (oldCategoryId == categoryId) return;
      String? oldName;
      String? newName;
      if (oldCategoryId != null) {
        final oldRows = await txn.query('categories', columns: ['name'],
          where: 'id = ?', whereArgs: [oldCategoryId], limit: 1);
        oldName = oldRows.isEmpty ? null : oldRows.first['name'] as String;
      }
      if (categoryId != null) {
        final categories = await txn.query(
          'categories', columns: ['name'],
          where: 'id = ?', whereArgs: [categoryId], limit: 1,
        );
        if (categories.isEmpty) throw StateError('Category no longer exists.');
        newName = categories.first['name'] as String;
      }
      final changed = await txn.update(
        'documents',
        {'category_id': categoryId, 'updated_at': DateTime.now().toUtc().toIso8601String()},
        where: 'id = ? AND deleted_at IS NULL', whereArgs: [documentId],
      );
      if (changed == 0) throw StateError('Document no longer exists.');
      await _recordHistory(txn, documentId, 'category_changed', {
        'from_category_id': oldCategoryId, 'from_category': oldName,
        'to_category_id': categoryId, 'to_category': newName,
      });
    });
    PortableSnapshotEvents.notifyDataChanged();
  }

  Future<void> _recordHistory(
    DatabaseExecutor txn,
    String? documentId,
    String action,
    Map<String, Object?> details,
  ) async {
    await txn.insert('history', {
      'id': _uuid.v4(),
      'document_id': documentId,
      'action': action,
      'details_json': jsonEncode(details),
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  @visibleForTesting
  static String validateName(String name) {
    final cleaned = name.trim();
    if (cleaned.isEmpty) throw ArgumentError('Name cannot be empty.');
    if (cleaned.length > 40) throw ArgumentError('Name must be 40 characters or fewer.');
    return cleaned;
  }
}
