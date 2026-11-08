import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import 'reminder_notifications.dart';

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
    required this.recurrenceRule,
  });

  final String id;
  final String title;
  final String? note;
  final DateTime remindAt;
  final bool enabled;
  final String status;
  final String? documentId;
  final String? documentName;
  final String? recurrenceRule;

  factory ReminderRecord.fromMap(Map<String, Object?> row) => ReminderRecord(
    id: row['id'] as String,
    title: row['title'] as String,
    note: row['note'] as String?,
    remindAt: DateTime.parse(row['remind_at_utc'] as String).toLocal(),
    enabled: (row['enabled'] as int) == 1,
    status: row['status'] as String,
    documentId: row['document_id'] as String?,
    documentName: row['document_name'] as String?,
    recurrenceRule: row['recurrence_rule'] as String?,
  );
}

class ReminderRepository {
  ReminderRepository({AppDatabase? database}) : _database = database ?? AppDatabase.instance;
  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<List<ReminderRecord>> list() async {
    final db = await _database.database;
    final rows = await db.rawQuery('''
      SELECT r.*, d.name AS document_name
      FROM reminders r LEFT JOIN documents d ON d.id = r.document_id
      ORDER BY r.remind_at_utc ASC
    ''');
    return rows.map(ReminderRecord.fromMap).toList();
  }

  /// Rebuilds pending OS notifications from the durable reminder records.
  /// Safe to call at startup and whenever the app returns to the foreground.
  Future<void> rescheduleEnabled() async {
    final db = await _database.database;
    final rows = await db.rawQuery('''
      SELECT r.*
      FROM reminders r
      LEFT JOIN documents d ON d.id = r.document_id
      WHERE r.enabled = 1
        AND r.status NOT IN (?, ?)
        AND (r.document_id IS NULL OR d.deleted_at IS NULL)
      ORDER BY r.remind_at_utc ASC
    ''', ['completed', 'cancelled']);
    await ReminderNotifications.instance.reconcile(rows);
  }

  Future<void> _ensureDocumentIsActive(String? documentId) async {
    if (documentId == null) return;
    final db = await _database.database;
    final rows = await db.query(
      'documents',
      columns: ['id'],
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [documentId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('The linked PDF is in the Recycle Bin or no longer exists.');
    }
  }

  Future<void> create({
    required String title,
    String? note,
    required DateTime remindAt,
    String? recurrenceRule,
    String? documentId,
  }) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) throw ArgumentError('Reminder title cannot be empty.');
    if (!remindAt.isAfter(DateTime.now())) {
      throw ArgumentError('Reminder date and time must be in the future.');
    }
    if (recurrenceRule != null && !const {'daily', 'weekly'}.contains(recurrenceRule)) {
      throw ArgumentError('Unsupported reminder recurrence.');
    }
    await _ensureDocumentIsActive(documentId);
    final db = await _database.database;
    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    final when = remindAt.toUtc().toIso8601String();
    final cleanNote = note?.trim();
    await db.insert('reminders', {
      'id': id,
      'document_id': documentId,
      'title': cleanTitle,
      'note': cleanNote == null || cleanNote.isEmpty ? null : cleanNote,
      'remind_at_utc': when,
      'timezone_id': DateTime.now().timeZoneName,
      'enabled': 1,
      'status': 'scheduled',
      'next_fire_at_utc': when,
      'recurrence_rule': recurrenceRule,
      'created_at': now,
      'updated_at': now,
    });
    await ReminderNotifications.instance.requestPermission();
    await ReminderNotifications.instance.schedule(
      id: id, title: cleanTitle, body: cleanNote, at: remindAt, recurrence: recurrenceRule,
    );
  }

  Future<void> update({
    required String id,
    required String title,
    String? note,
    required DateTime remindAt,
    String? recurrenceRule,
  }) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) throw ArgumentError('Reminder title cannot be empty.');
    if (!remindAt.isAfter(DateTime.now())) {
      throw ArgumentError('Reminder date and time must be in the future.');
    }
    if (recurrenceRule != null && !const {'daily', 'weekly'}.contains(recurrenceRule)) {
      throw ArgumentError('Unsupported reminder recurrence.');
    }
    final db = await _database.database;
    final existing = await db.query(
      'reminders',
      columns: ['document_id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (existing.isEmpty) throw StateError('Reminder no longer exists.');
    await _ensureDocumentIsActive(existing.first['document_id'] as String?);
    final when = remindAt.toUtc().toIso8601String();
    final cleanNote = note?.trim();
    await db.update('reminders', {
      'title': cleanTitle,
      'note': cleanNote == null || cleanNote.isEmpty ? null : cleanNote,
      'remind_at_utc': when,
      'next_fire_at_utc': when,
      'recurrence_rule': recurrenceRule,
      'status': 'scheduled',
      'completed_at': null,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, where: 'id = ?', whereArgs: [id]);
    await ReminderNotifications.instance.cancel(id);
    await ReminderNotifications.instance.schedule(
      id: id, title: cleanTitle, body: cleanNote, at: remindAt, recurrence: recurrenceRule,
    );
  }

  Future<void> snooze(ReminderRecord reminder, {Duration duration = const Duration(days: 1)}) async {
    if (duration <= Duration.zero) throw ArgumentError('Snooze duration must be positive.');
    await _ensureDocumentIsActive(reminder.documentId);
    final when = DateTime.now().add(duration);
    final db = await _database.database;
    await db.update('reminders', {
      'remind_at_utc': when.toUtc().toIso8601String(),
      'next_fire_at_utc': when.toUtc().toIso8601String(),
      'status': 'scheduled',
      'enabled': 1,
      'snoozed_until': when.toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, where: 'id = ?', whereArgs: [reminder.id]);
    await ReminderNotifications.instance.schedule(
      id: reminder.id, title: reminder.title, body: reminder.note, at: when,
    );
  }

  Future<void> duplicate(ReminderRecord reminder) => create(
    title: '${reminder.title} (copy)',
    note: reminder.note,
    remindAt: reminder.remindAt.isAfter(DateTime.now())
      ? reminder.remindAt : DateTime.now().add(const Duration(days: 1)),
    recurrenceRule: reminder.recurrenceRule,
    documentId: reminder.documentId,
  );

  Future<void> setEnabled(ReminderRecord reminder, bool enabled) async {
    if (enabled) await _ensureDocumentIsActive(reminder.documentId);
    final db = await _database.database;
    await db.update('reminders', {
      'enabled': enabled ? 1 : 0,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, where: 'id = ?', whereArgs: [reminder.id]);
    if (enabled) {
      await ReminderNotifications.instance.schedule(
        id: reminder.id, title: reminder.title, body: reminder.note,
        at: reminder.remindAt, recurrence: reminder.recurrenceRule,
      );
    } else {
      await ReminderNotifications.instance.cancel(reminder.id);
    }
  }

  Future<void> delete(String id) async {
    final db = await _database.database;
    await db.delete('reminders', where: 'id = ?', whereArgs: [id]);
    await ReminderNotifications.instance.cancel(id);
  }

  Future<void> complete(String id) async {
    final db = await _database.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.update('reminders', {
      'status': 'completed', 'completed_at': now, 'enabled': 0, 'updated_at': now,
    }, where: 'id = ?', whereArgs: [id]);
    await ReminderNotifications.instance.cancel(id);
  }
}
