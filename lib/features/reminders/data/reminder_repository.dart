import 'package:flutter/foundation.dart';
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
    this.snoozedUntil,
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
  final DateTime? snoozedUntil;

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
    snoozedUntil: row['snoozed_until'] == null
        ? null
        : DateTime.parse(row['snoozed_until'] as String).toLocal(),
  );
}

abstract interface class ReminderNotificationGateway {
  Future<void> cancel(String id);
  Future<void> schedule({
    required String id,
    required String title,
    String? body,
    required DateTime at,
    String? recurrence,
  });
  Future<void> scheduleSnooze({
    required String id,
    required String title,
    String? body,
    required DateTime at,
  });
  Future<bool> requestPermission();
}

class _PluginReminderNotificationGateway implements ReminderNotificationGateway {
  @override
  Future<void> cancel(String id) => ReminderNotifications.instance.cancel(id);

  @override
  Future<void> schedule({
    required String id,
    required String title,
    String? body,
    required DateTime at,
    String? recurrence,
  }) => ReminderNotifications.instance.schedule(
    id: id, title: title, body: body, at: at, recurrence: recurrence,
  );

  @override
  Future<void> scheduleSnooze({
    required String id,
    required String title,
    String? body,
    required DateTime at,
  }) => ReminderNotifications.instance.scheduleSnooze(
    id: id, title: title, body: body, at: at,
  );

  @override
  Future<bool> requestPermission() => ReminderNotifications.instance.requestPermission();
}

class ReminderRepository {
  ReminderRepository({AppDatabase? database, ReminderNotificationGateway? notifications})
      : _database = database ?? AppDatabase.instance,
        _notifications = notifications ?? _PluginReminderNotificationGateway();

  final AppDatabase _database;
  final ReminderNotificationGateway _notifications;
  static const _uuid = Uuid();

  @visibleForTesting
  static bool shouldHaveScheduledNotification({
    required int enabled,
    required String status,
  }) => enabled == 1 && status == 'scheduled';

  /// Reconciles SQLite reminder state with OS notifications after startup or
  /// app resume. A DB commit can succeed while the OS scheduler is unavailable;
  /// replaying the desired state makes those failures recoverable.
  Future<int> reconcileNotifications() async {
    final db = await _database.database;
    final rows = await db.query('reminders');
    var failures = 0;
    for (final row in rows) {
      final id = row['id'] as String;
      try {
        if (!shouldHaveScheduledNotification(
          enabled: row['enabled'] as int,
          status: row['status'] as String,
        )) {
          await _notifications.cancel(id);
          continue;
        }

        final remindAt = DateTime.parse(row['remind_at_utc'] as String).toLocal();
        final recurrence = row['recurrence_rule'] as String?;
        final rawSnooze = row['snoozed_until'] as String?;
        final snoozedUntil = rawSnooze == null ? null : DateTime.parse(rawSnooze).toLocal();
        final title = row['title'] as String;
        final note = row['note'] as String?;

        if (recurrence != null || snoozedUntil == null || !snoozedUntil.isAfter(DateTime.now())) {
          await _notifications.schedule(
            id: id,
            title: title,
            body: note,
            at: remindAt,
            recurrence: recurrence,
          );
        }
        if (snoozedUntil != null && snoozedUntil.isAfter(DateTime.now())) {
          await _notifications.scheduleSnooze(
            id: id,
            title: title,
            body: note,
            at: snoozedUntil,
          );
        }
      } catch (_) {
        // Keep the persisted reminder. A later resume will retry reconciliation.
        failures++;
      }
    }
    return failures;
  }

  Future<List<ReminderRecord>> list() async {
    final db = await _database.database;
    final rows = await db.rawQuery('''
      SELECT r.*, d.name AS document_name
      FROM reminders r LEFT JOIN documents d ON d.id = r.document_id
      ORDER BY r.remind_at_utc ASC
    ''');
    return rows.map(ReminderRecord.fromMap).toList();
  }

  Future<void> create({
    required String title,
    String? note,
    required DateTime remindAt,
    String? recurrenceRule,
    String? documentId,
  }) async {
    final db = await _database.database;
    final id = _uuid.v4();
    final now = DateTime.now().toUtc().toIso8601String();
    final when = remindAt.toUtc().toIso8601String();
    final cleanNote = note?.trim();
    await db.insert('reminders', {
      'id': id,
      'document_id': documentId,
      'title': title.trim(),
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
    await _notifications.requestPermission();
    await _notifications.schedule(
      id: id, title: title.trim(), body: cleanNote, at: remindAt, recurrence: recurrenceRule,
    );
  }

  Future<void> update({
    required String id,
    required String title,
    String? note,
    required DateTime remindAt,
    String? recurrenceRule,
  }) async {
    final db = await _database.database;
    final when = remindAt.toUtc().toIso8601String();
    final cleanNote = note?.trim();
    final changed = await db.update('reminders', {
      'title': title.trim(),
      'note': cleanNote == null || cleanNote.isEmpty ? null : cleanNote,
      'remind_at_utc': when,
      'next_fire_at_utc': when,
      'recurrence_rule': recurrenceRule,
      'snoozed_until': null,
      'status': 'scheduled',
      'completed_at': null,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, where: 'id = ?', whereArgs: [id]);
    if (changed == 0) throw StateError('Reminder no longer exists.');
    await _notifications.cancel(id);
    await _notifications.schedule(
      id: id, title: title.trim(), body: cleanNote, at: remindAt, recurrence: recurrenceRule,
    );
  }

  Future<void> snooze(ReminderRecord reminder, {Duration duration = const Duration(days: 1)}) async {
    final when = DateTime.now().add(duration);
    final db = await _database.database;
    final changed = await db.update('reminders', {
      // Keep the original recurrence anchor; snooze is a separate one-off.
      'next_fire_at_utc': when.toUtc().toIso8601String(),
      'status': 'scheduled',
      'enabled': 1,
      'snoozed_until': when.toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, where: 'id = ?', whereArgs: [reminder.id]);
    if (changed == 0) throw StateError('Reminder no longer exists.');
    if (reminder.recurrenceRule != null) {
      await _notifications.schedule(
        id: reminder.id,
        title: reminder.title,
        body: reminder.note,
        at: reminder.remindAt,
        recurrence: reminder.recurrenceRule,
      );
    }
    await _notifications.scheduleSnooze(
      id: reminder.id, title: reminder.title, body: reminder.note, at: when,
    );
  }

  Future<void> duplicate(ReminderRecord reminder) => create(
    title: '${reminder.title} (copy)',
    note: reminder.note,
    remindAt: reminder.remindAt.isAfter(DateTime.now())
      ? reminder.remindAt : DateTime.now().add(const Duration(days: 1)),
    recurrenceRule: reminder.recurrenceRule,
  );

  Future<void> setEnabled(ReminderRecord reminder, bool enabled) async {
    final db = await _database.database;
    final rows = await db.query(
      'reminders',
      columns: ['snoozed_until'],
      where: 'id = ?',
      whereArgs: [reminder.id],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Reminder no longer exists.');
    final changed = await db.update('reminders', {
      'enabled': enabled ? 1 : 0,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, where: 'id = ?', whereArgs: [reminder.id]);
    if (changed == 0) throw StateError('Reminder no longer exists.');
    if (enabled) {
      await _notifications.schedule(
        id: reminder.id, title: reminder.title, body: reminder.note,
        at: reminder.remindAt, recurrence: reminder.recurrenceRule,
      );
      final rawSnoozedUntil = rows.first['snoozed_until'] as String?;
      final snoozedUntil = rawSnoozedUntil == null ? null : DateTime.parse(rawSnoozedUntil).toLocal();
      if (snoozedUntil != null && snoozedUntil.isAfter(DateTime.now())) {
        await _notifications.scheduleSnooze(
          id: reminder.id, title: reminder.title, body: reminder.note, at: snoozedUntil,
        );
      }
    } else {
      await _notifications.cancel(reminder.id);
    }
  }

  Future<void> delete(String id) async {
    final db = await _database.database;
    await db.delete('reminders', where: 'id = ?', whereArgs: [id]);
    await _notifications.cancel(id);
  }

  Future<void> complete(String id) async {
    final db = await _database.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.update('reminders', {
      'status': 'completed', 'completed_at': now, 'enabled': 0, 'updated_at': now,
    }, where: 'id = ?', whereArgs: [id]);
    await _notifications.cancel(id);
  }
}
