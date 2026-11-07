import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';

class ReminderRecord {
  const ReminderRecord({
    required this.id,
    required this.title,
    required this.note,
    required this.remindAt,
    required this.enabled,
    required this.status,
    required this.documentId,
    required this.documentName,
  });

  final String id;
  final String title;
  final String? note;
  final DateTime remindAt;
  final bool enabled;
  final String status;
  final String? documentId;
  final String? documentName;

  factory ReminderRecord.fromMap(Map<String, Object?> row) => ReminderRecord(
        id: row['id'] as String,
        title: row['title'] as String,
        note: row['note'] as String?,
        remindAt: DateTime.parse(row['remind_at_utc'] as String).toLocal(),
        enabled: (row['enabled'] as int) == 1,
        status: row['status'] as String,
        documentId: row['document_id'] as String?,
        documentName: row['document_name'] as String?,
      );
}

class ReminderRepository {
  ReminderRepository({AppDatabase? database})
      : _database = database ?? AppDatabase.instance;

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<List<ReminderRecord>> list() async {
    final db = await _database.database;
    final rows = await db.rawQuery('''
      SELECT r.*, d.name AS document_name
      FROM reminders r
      LEFT JOIN documents d ON d.id = r.document_id
      ORDER BY r.remind_at_utc ASC
    ''');
    return rows.map(ReminderRecord.fromMap).toList();
  }

  Future<void> create({
    required String title,
    String? note,
    required DateTime remindAt,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toUtc().toIso8601String();
    final when = remindAt.toUtc().toIso8601String();
    await db.insert('reminders', {
      'id': _uuid.v4(),
      'title': title.trim(),
      'note': note?.trim().isEmpty == true ? null : note?.trim(),
      'remind_at_utc': when,
      'timezone_id': DateTime.now().timeZoneName,
      'enabled': 1,
      'status': 'scheduled',
      'next_fire_at_utc': when,
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<void> setEnabled(ReminderRecord reminder, bool enabled) async {
    final db = await _database.database;
    await db.update('reminders', {
      'enabled': enabled ? 1 : 0,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, where: 'id = ?', whereArgs: [reminder.id]);
  }

  Future<void> delete(String id) async {
    final db = await _database.database;
    await db.delete('reminders', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> complete(String id) async {
    final db = await _database.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.update('reminders', {
      'status': 'completed',
      'completed_at': now,
      'enabled': 0,
      'updated_at': now,
    }, where: 'id = ?', whereArgs: [id]);
  }
}
