import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/reminders/data/reminder_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

class _ReminderRowsDatabase implements Database {
  _ReminderRowsDatabase(this.rows);
  final List<Map<String, Object?>> rows;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #query) {
      return Future<List<Map<String, Object?>>>.value(rows);
    }
    if (invocation.memberName == #insert) {
      final values = Map<String, Object?>.from(
        invocation.positionalArguments[1] as Map,
      );
      rows.add(values);
      return Future<int>.value(1);
    }
    return super.noSuchMethod(invocation);
  }
}

class _FailingNotificationGateway implements ReminderNotificationGateway {
  var scheduleCalls = 0;
  var cancelCalls = 0;

  @override
  Future<void> cancel(String id) async {
    cancelCalls++;
    throw StateError('OS notification service unavailable');
  }

  @override
  Future<void> schedule({
    required String id,
    required String title,
    String? body,
    required DateTime at,
    String? recurrence,
  }) async {
    scheduleCalls++;
    throw StateError('OS notification service unavailable');
  }

  @override
  Future<void> scheduleSnooze({
    required String id,
    required String title,
    String? body,
    required DateTime at,
  }) async {
    throw StateError('OS notification service unavailable');
  }

  @override
  Future<bool> requestPermission() async => false;
}


class _RetryNotificationGateway implements ReminderNotificationGateway {
  var scheduleCalls = 0;
  final scheduledIds = <String>[];

  @override
  Future<void> cancel(String id) async {}

  @override
  Future<void> schedule({
    required String id,
    required String title,
    String? body,
    required DateTime at,
    String? recurrence,
  }) async {
    scheduleCalls++;
    scheduledIds.add(id);
    if (scheduleCalls == 1) {
      throw StateError('temporary scheduler outage');
    }
  }

  @override
  Future<void> scheduleSnooze({
    required String id,
    required String title,
    String? body,
    required DateTime at,
  }) async {}

  @override
  Future<bool> requestPermission() async => true;
}

void main() {
  test('create keeps the committed reminder when OS scheduling throws', () async {
    final db = _ReminderRowsDatabase([]);
    final gateway = _FailingNotificationGateway();
    final repository = ReminderRepository(
      database: AppDatabase.forTesting(() async => db),
      notifications: gateway,
    );

    await expectLater(
      repository.create(
        title: 'Renew policy',
        note: 'Call insurer',
        remindAt: DateTime.now().add(const Duration(days: 3)),
      ),
      throwsStateError,
    );

    expect(db.rows, hasLength(1));
    expect(db.rows.single['title'], 'Renew policy');
    expect(db.rows.single['status'], 'scheduled');
    expect(db.rows.single['enabled'], 1);
    expect(gateway.scheduleCalls, 1);
  });

  test('scheduler failure is counted and persisted reminder is retained', () async {
    final row = <String, Object?>{
      'id': 'reminder-active',
      'enabled': 1,
      'status': 'scheduled',
      'remind_at_utc': DateTime.now().add(const Duration(days: 2)).toUtc().toIso8601String(),
      'recurrence_rule': null,
      'snoozed_until': null,
      'title': 'Renew policy',
      'note': 'Call insurer',
    };
    final db = _ReminderRowsDatabase([row]);
    final gateway = _FailingNotificationGateway();
    final repository = ReminderRepository(
      database: AppDatabase.forTesting(() async => db),
      notifications: gateway,
    );

    final failures = await repository.reconcileNotifications();

    expect(failures, 1);
    expect(gateway.scheduleCalls, 1);
    expect(db.rows, contains(row));
    expect(row['status'], 'scheduled');
    expect(row['enabled'], 1);
  });

  test('cancellation failure is counted without deleting completed reminder', () async {
    final row = <String, Object?>{
      'id': 'reminder-completed',
      'enabled': 0,
      'status': 'completed',
      'remind_at_utc': DateTime.now().toUtc().toIso8601String(),
      'recurrence_rule': null,
      'snoozed_until': null,
      'title': 'Old reminder',
      'note': null,
    };
    final db = _ReminderRowsDatabase([row]);
    final gateway = _FailingNotificationGateway();
    final repository = ReminderRepository(
      database: AppDatabase.forTesting(() async => db),
      notifications: gateway,
    );

    final failures = await repository.reconcileNotifications();

    expect(failures, 1);
    expect(gateway.cancelCalls, 1);
    expect(db.rows, contains(row));
    expect(row['status'], 'completed');
  });

  test('reconciliation retries a failed schedule using the stable reminder id', () async {
    final row = <String, Object?>{
      'id': 'reminder-retry-stable',
      'enabled': 1,
      'status': 'scheduled',
      'remind_at_utc': DateTime.now().add(const Duration(days: 2)).toUtc().toIso8601String(),
      'recurrence_rule': null,
      'snoozed_until': null,
      'title': 'Renew policy',
      'note': null,
    };
    final db = _ReminderRowsDatabase([row]);
    final gateway = _RetryNotificationGateway();
    final repository = ReminderRepository(
      database: AppDatabase.forTesting(() async => db),
      notifications: gateway,
    );

    expect(await repository.reconcileNotifications(), 1);
    expect(await repository.reconcileNotifications(), 0);
    expect(gateway.scheduleCalls, 2);
    expect(gateway.scheduledIds, ['reminder-retry-stable', 'reminder-retry-stable']);
    expect(db.rows.single['status'], 'scheduled');
    expect(db.rows.single['enabled'], 1);
  });


}
