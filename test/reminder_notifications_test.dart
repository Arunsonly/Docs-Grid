import 'package:docs_grid/features/reminders/data/reminder_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReminderNotifications.notificationIdFor', () {
    test('is stable for the same reminder ID', () {
      expect(
        ReminderNotifications.notificationIdFor('reminder-123'),
        ReminderNotifications.notificationIdFor('reminder-123'),
      );
    });

    test('produces a valid non-negative platform notification ID', () {
      final id = ReminderNotifications.notificationIdFor('reminder-123');
      expect(id, inInclusiveRange(0, 0x7fffffff));
    });

    test('different reminder IDs produce different IDs in representative cases', () {
      expect(
        ReminderNotifications.notificationIdFor('reminder-123'),
        isNot(ReminderNotifications.notificationIdFor('reminder-124')),
      );
    });

    test('snooze IDs are stable and separate from the recurring reminder ID', () {
      final snoozeId = ReminderNotifications.snoozeNotificationIdFor('reminder-123');
      expect(snoozeId, ReminderNotifications.snoozeNotificationIdFor('reminder-123'));
      expect(snoozeId, isNot(ReminderNotifications.notificationIdFor('reminder-123')));
    });
  });

  group('ReminderNotifications.nextScheduledOccurrence', () {
    test('keeps a future one-time reminder unchanged', () {
      final at = DateTime(2026, 12, 10, 9);
      expect(ReminderNotifications.nextScheduledOccurrence(
        at: at, now: DateTime(2026, 12, 1),
      ), at);
    });

    test('advances an expired daily reminder to the next day', () {
      expect(ReminderNotifications.nextScheduledOccurrence(
        at: DateTime(2026, 10, 1, 9), now: DateTime(2026, 11, 8, 10), recurrence: 'daily',
      ), DateTime(2026, 11, 9, 9));
    });

    test('advances an expired weekly reminder to the next matching weekday', () {
      expect(ReminderNotifications.nextScheduledOccurrence(
        at: DateTime(2026, 10, 2, 9), now: DateTime(2026, 11, 8, 10), recurrence: 'weekly',
      ), DateTime(2026, 11, 13, 9));
    });

    test('advances monthly reminders while retaining the selected day', () {
      expect(ReminderNotifications.nextScheduledOccurrence(
        at: DateTime(2026, 10, 15, 9), now: DateTime(2026, 11, 20, 10), recurrence: 'monthly',
      ), DateTime(2026, 12, 15, 9));
    });

    test('skips months that do not contain the selected day', () {
      expect(ReminderNotifications.nextScheduledOccurrence(
        at: DateTime(2026, 1, 31, 9), now: DateTime(2026, 2, 1), recurrence: 'monthly',
      ), DateTime(2026, 3, 31, 9));
    });

    test('returns null for an expired one-time reminder', () {
      expect(ReminderNotifications.nextScheduledOccurrence(
        at: DateTime(2026, 10, 1), now: DateTime(2026, 11, 1),
      ), isNull);
    });
  });
}
