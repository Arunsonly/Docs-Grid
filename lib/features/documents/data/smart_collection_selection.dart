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

  String get mode {
    final value = row['selection_mode'];
    return value == 'manual' || value == 'hybrid' ? value as String : 'automatic';
  }
  Set<String> get included => ids(row['included_ids_json']);
  Set<String> get excluded => ids(row['excluded_ids_json']);

  // Legacy name/star/recent predicates remain active only for unedited old collections.
  ({String sql, List<Object?> args}) get predicate {
    final where = <String>['1=1'];
    final args = <Object?>[];
    if (row['favorites_only'] == 1) where.add('d.is_favorite = 1');
    if (row['recent_only'] == 1) where.add('d.last_opened_at IS NOT NULL');
    final query = (row['query_text'] as String? ?? '').trim();
    if (query.isNotEmpty) {
      where.add("d.name LIKE ? ESCAPE '\\'");
      args.add('%' + query.replaceAll('\\', '\\\\').replaceAll('%', r'\%').replaceAll('_', r'\_') + '%');
    }
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

  Future<List<Map<String, Object?>>> candidates(Database db) async {
    final p = predicate;
    return db.rawQuery(
      'SELECT d.id, d.name, d.size_bytes, d.is_favorite, d.storage_uri, '
      'CASE WHEN (' + p.sql + ') THEN 1 ELSE 0 END AS rule_match '
      'FROM documents d WHERE d.deleted_at IS NULL ORDER BY d.name COLLATE NOCASE, d.id',
      p.args);
  }

  bool contains(Map<String, Object?> document) {
    final id = document['id'] as String;
    final match = document['rule_match'] == 1;
    if (mode == 'manual') return included.contains(id);
    if (mode == 'hybrid') return !excluded.contains(id) && (match || included.contains(id));
    return match;
  }

  Future<List<Map<String, Object?>>> results(Database db) async {
    final p = predicate;
    if (mode == 'automatic') {
      return db.rawQuery(
        'SELECT d.id, d.name, d.size_bytes, d.is_favorite, d.storage_uri FROM documents d '
        'WHERE d.deleted_at IS NULL AND (' + p.sql + ') ORDER BY d.name COLLATE NOCASE, d.id',
        p.args);
    }
    final include = included, exclude = excluded;
    return (await candidates(db)).where((doc) {
      final id = doc['id'] as String;
      return mode == 'manual' ? include.contains(id) :
        !exclude.contains(id) && (doc['rule_match'] == 1 || include.contains(id));
    }).toList();
  }

  Future<int> count(Database db) async {
    if (mode != 'automatic') return (await results(db)).length;
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
