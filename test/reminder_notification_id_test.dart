import 'package:docs_grid/features/reminders/data/reminder_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('notification IDs are deterministic across app launches', () {
    expect(ReminderNotifications.stableNotificationId('reminder-123'), 1605179106);
    expect(ReminderNotifications.stableNotificationId('another-reminder'), 1282023705);
    expect(
      ReminderNotifications.stableNotificationId('reminder-123'),
      ReminderNotifications.stableNotificationId('reminder-123'),
    );
  });
}
