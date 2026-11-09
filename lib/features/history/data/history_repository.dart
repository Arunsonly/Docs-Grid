import 'dart:convert';

import '../../../core/database/app_database.dart';

class ActivityRecord {
  const ActivityRecord({
    required this.id,
    required this.action,
    required this.documentName,
    required this.createdAt,
    required this.details,
  });

  final String id;
  final String action;
  final String? documentName;
  final DateTime createdAt;
  final Map<String, dynamic> details;

  factory ActivityRecord.fromMap(Map<String, Object?> row) {
    Map<String, dynamic> details;
    try {
      final decoded = jsonDecode((row['details_json'] as String?) ?? '{}');
      details = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      details = <String, dynamic>{};
    }
    final rawCreatedAt = row['created_at'];
    final parsedCreatedAt = rawCreatedAt is String
        ? DateTime.tryParse(rawCreatedAt)
        : null;
    final rawDocumentName = row['document_name'];
    return ActivityRecord(
      id: row['id'] as String,
      action: row['action'] is String ? row['action'] as String : 'unknown',
      documentName: rawDocumentName is String ? rawDocumentName : null,
      createdAt: (parsedCreatedAt ?? DateTime.fromMillisecondsSinceEpoch(0)).toLocal(),
      details: details,
    );
  }
}

class HistoryRepository {
  HistoryRepository({AppDatabase? database})
      : _database = database ?? AppDatabase.instance;

  final AppDatabase _database;

  Future<List<ActivityRecord>> list({int limit = 200}) async {
    final db = await _database.database;
    final rows = await db.rawQuery('''
      SELECT h.*, d.name AS document_name
      FROM history h
      LEFT JOIN documents d ON d.id = h.document_id
      ORDER BY h.created_at DESC
      LIMIT ?
    ''', [limit]);
    return rows.map(ActivityRecord.fromMap).toList();
  }

  Future<void> clear() async {
    final db = await _database.database;
    await db.delete('history');
  }
}
