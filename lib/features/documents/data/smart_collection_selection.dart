import 'dart:convert';
import 'package:sqflite/sqflite.dart';

class SmartCollectionSelection {
  SmartCollectionSelection(this.row);
  final Map<String, Object?> row;

  static Set<String> ids(Object? raw) {
    try {
      final decoded = jsonDecode(raw as String? ?? '[]');
      return decoded is List ? decoded.whereType<String>().toSet() : <String>{};
    } catch (_) { return <String>{}; }
  }

  ({String sql, List<Object?> args}) get predicate {
    final where = <String>['1=1'];
    final args = <Object?>[];
    if (row['missing_category'] == true) where.add('d.category_id IS NULL');
    if (row['missing_tags'] == true) where.add('NOT EXISTS (SELECT 1 FROM document_tags dt WHERE dt.document_id = d.id)');
    final category = row['category_id'] as String?;
    if (category != null && category.isNotEmpty) {
      where.add('d.category_id = ?');
      args.add(category);
    }
    for (final tag in ids(row['tag_ids_json'])) {
      where.add('EXISTS (SELECT 1 FROM document_tags dt WHERE dt.document_id = d.id AND dt.tag_id = ?)');
      args.add(tag);
    }
    return (sql: where.join(' AND '), args: args);
  }

  // All collections are automatic, including rows from older backups.
  // Retain obsolete columns for compatibility, never use them as predicates.
  Future<List<Map<String, Object?>>> results(Database db) async {
    final p = predicate;
    return db.rawQuery(
      'SELECT d.id, d.name, d.size_bytes, d.is_favorite, d.storage_uri FROM documents d '
      'WHERE d.deleted_at IS NULL AND (' + p.sql + ') ORDER BY d.name COLLATE NOCASE, d.id',
      p.args);
  }

  Future<int> count(Database db) async {
    final p = predicate;
    final rows = await db.rawQuery('SELECT COUNT(*) AS total FROM documents d WHERE d.deleted_at IS NULL AND (' + p.sql + ')', p.args);
    return (rows.single['total'] as num).toInt();
  }

  /// Translate saved references using the same IDs as the restored documents,
  /// categories and tags. Unmapped references must not match unrelated local IDs.
  static Map<String, Object?> remap(Map<String, Object?> row, {
    required Map<String, String> documentIds,
    required Map<String, String> categoryIds,
    required Map<String, String> tagIds,
  }) {
    String mapped(String id, Map<String, String> map) =>
        map[id] ?? 'missing-collection-reference:' + id;
    final copy = Map<String, Object?>.from(row);
    final category = row['category_id'] as String?;
    if (category != null && category.isNotEmpty) {
      copy['category_id'] = mapped(category, categoryIds);
    }
    for (final (field, map) in [
      ('tag_ids_json', tagIds), ('included_ids_json', documentIds),
      ('excluded_ids_json', documentIds),
    ]) {
      if (row.containsKey(field)) {
        copy[field] = jsonEncode(ids(row[field]).map((id) => mapped(id, map)).toSet().toList());
      }
    }
    return copy;
  }
}
