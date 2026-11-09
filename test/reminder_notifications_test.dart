import 'package:docs_grid/features/reminders/data/reminder_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('snooze IDs are stable and independent from recurring reminder IDs', () {
    final reminderId = 'reminder-123';
    final baseId = ReminderNotifications.stableNotificationId(reminderId);
    final snoozeId = ReminderNotifications.stableSnoozeNotificationId(reminderId);
    expect(snoozeId, isNot(baseId));
    expect(snoozeId, ReminderNotifications.stableSnoozeNotificationId(reminderId));
  });

  group('ReminderNotifications.nextScheduledOccurrence', () {
    test('keeps a future one-time reminder unchanged', () {
      final at = DateTime(2026, 12, 10, 9);
      expect(ReminderNotifications.nextScheduledOccurrence(
        at: at, now: DateTime(2026, 12, 1),
      ), at);
    });

    test('advances an expired daily reminder to the next day', () {
      final next = ReminderNotifications.nextScheduledOccurrence(
        at: DateTime(2026, 10, 1, 9), now: DateTime(2026, 11, 8, 10), recurrence: 'daily',
      );
      expect(next, DateTime(2026, 11, 9, 9));
    });

    test('advances an expired weekly reminder to the next matching weekday', () {
      final next = ReminderNotifications.nextScheduledOccurrence(
        at: DateTime(2026, 10, 2, 9), now: DateTime(2026, 11, 8, 10), recurrence: 'weekly',
      );
      expect(next, DateTime(2026, 11, 13, 9));
    });

    test('advances monthly reminders while retaining the selected day', () {
      final next = ReminderNotifications.nextScheduledOccurrence(
        at: DateTime(2026, 10, 15, 9), now: DateTime(2026, 11, 20, 10), recurrence: 'monthly',
      );
      expect(next, DateTime(2026, 12, 15, 9));
    });

    test('skips months that do not contain a 29th, 30th or 31st', () {
      final next = ReminderNotifications.nextScheduledOccurrence(
        at: DateTime(2026, 1, 31, 9), now: DateTime(2026, 2, 1), recurrence: 'monthly',
      );
      expect(next, DateTime(2026, 3, 31, 9));
    });

    test('returns null for an expired one-time reminder', () {
      expect(ReminderNotifications.nextScheduledOccurrence(
        at: DateTime(2026, 10, 1), now: DateTime(2026, 11, 1),
      ), isNull);
    });
  });
}
