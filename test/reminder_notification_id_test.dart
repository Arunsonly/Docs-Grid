import 'package:docs_grid/features/reminders/data/reminder_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReminderNotifications.nextScheduledOccurrence', () {
    test('moves an overdue daily reminder to the next local clock time', () {
      final next = ReminderNotifications.nextScheduledOccurrence(
        at: DateTime(2026, 11, 7, 9),
        now: DateTime(2026, 11, 8, 10),
        recurrence: 'daily',
      );
      expect(next, DateTime(2026, 11, 9, 9));
    });

    test('keeps a weekly reminder on its weekday and wall-clock time', () {
      final next = ReminderNotifications.nextScheduledOccurrence(
        at: DateTime(2026, 11, 1, 11),
        now: DateTime(2026, 11, 8, 10),
        recurrence: 'weekly',
      );
      expect(next, DateTime(2026, 11, 8, 11));
    });

    test('does not revive an overdue one-time reminder', () {
      expect(
        ReminderNotifications.nextScheduledOccurrence(
          at: DateTime(2026, 11, 7, 9),
          now: DateTime(2026, 11, 8, 10),
        ),
        isNull,
      );
    });
  });

  test('notification IDs are deterministic across app launches', () {
    expect(ReminderNotifications.stableNotificationId('reminder-123'), 1605179106);
    expect(ReminderNotifications.stableNotificationId('another-reminder'), 1282023705);
    expect(
      ReminderNotifications.stableNotificationId('reminder-123'),
      ReminderNotifications.stableNotificationId('reminder-123'),
    );
  });
}
