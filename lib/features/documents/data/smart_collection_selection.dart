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

  // v2 modes opt in explicitly; previously disabled legacy filters remain
  // disabled after upgrade and backup restoration.
  String get mode => const {'auto_v2','manual_v2','hybrid_v2'}.contains(row['selection_mode'])
      ? row['selection_mode'] as String : 'automatic';
  String get nameRule => mode == 'automatic' ? '' : (row['query_text'] as String? ?? '').trim();

  ({String sql, List<Object?> args}) get predicate {
    final where = <String>['1=1'];
    final args = <Object?>[];
    final query = nameRule;
    if (query.isNotEmpty) {
      where.add("d.name LIKE ? ESCAPE '\\'");
      args.add('%' + query.replaceAll('\\','\\\\').replaceAll('%',r'\%').replaceAll('_',r'\_') + '%');
    }
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

  Future<List<Map<String,Object?>>> candidates(Database db) async {
    final p = predicate;
    return db.rawQuery(
      'SELECT d.id, d.name, d.size_bytes, d.storage_uri, d.is_favorite, '
      'CASE WHEN (' + p.sql + ') THEN 1 ELSE 0 END AS rule_match '
      'FROM documents d WHERE d.deleted_at IS NULL ORDER BY d.name COLLATE NOCASE,d.id',
      p.args);
  }

  Set<String> chosenIds(List<Map<String,Object?>> rows) {
    final included = ids(row['included_ids_json']);
    final excluded = ids(row['excluded_ids_json']);
    return {
      for (final doc in rows)
        if (mode == 'manual_v2' ? included.contains(doc['id']) :
            mode == 'hybrid_v2' ? !excluded.contains(doc['id']) &&
                (doc['rule_match'] == 1 || included.contains(doc['id'])) :
                doc['rule_match'] == 1)
          doc['id'] as String,
    };
  }

  Future<List<Map<String, Object?>>> results(Database db) async {
    if (mode == 'manual_v2' || mode == 'hybrid_v2') {
      final rows = await candidates(db);
      final chosen = chosenIds(rows);
      return rows.where((doc) => chosen.contains(doc['id'])).toList();
    }
    final p = predicate;
    return db.rawQuery(
      'SELECT d.id, d.name, d.size_bytes, d.is_favorite, d.storage_uri FROM documents d '
      'WHERE d.deleted_at IS NULL AND (' + p.sql + ') ORDER BY d.name COLLATE NOCASE, d.id',
      p.args);
  }

  Future<int> count(Database db) async {
    if (mode == 'manual_v2' || mode == 'hybrid_v2') return (await results(db)).length;
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
