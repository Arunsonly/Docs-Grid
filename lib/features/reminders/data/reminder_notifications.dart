import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Device-local notification scheduler. Reminder contents remain on-device.
class ReminderNotifications {
  ReminderNotifications._();
  static final ReminderNotifications instance = ReminderNotifications._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> initialize() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    final deviceTimeZone = await FlutterTimezone.getLocalTimezone();
    // Android vendors may still report legacy IANA aliases.
    final reportedId = deviceTimeZone.identifier;
    final canonicalId = switch (reportedId) {
      'Asia/Calcutta' => 'Asia/Kolkata',
      'Asia/Katmandu' => 'Asia/Kathmandu',
      'Asia/Rangoon' => 'Asia/Yangon',
      _ => reportedId,
    };
    try {
      tz.setLocalLocation(tz.getLocation(canonicalId));
    } on Exception {
      // Fall back to the device's UTC offset instead of crashing the
      // reminder screen when a vendor returns an unknown timezone alias.
      tz.setLocalLocation(tz.UTC);
    }
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(settings);
    _ready = true;
  }

  Future<bool> requestPermission() async {
    await initialize();
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final androidGranted = await android?.requestNotificationsPermission() ?? true;
    if (android != null) {
      final exactAllowed = await android.canScheduleExactNotifications() ?? false;
      if (!exactAllowed) await android.requestExactAlarmsPermission();
    }
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    final iosGranted = await ios?.requestPermissions(alert: true, badge: true, sound: true) ?? true;
    return androidGranted && iosGranted;
  }

  int _id(String id) => id.hashCode & 0x7fffffff;

  Future<void> schedule({
    required String id,
    required String title,
    String? body,
    required DateTime at,
    String? recurrence,
  }) async {
    await initialize();
    if (!at.isAfter(DateTime.now())) {
      await cancel(id);
      return;
    }
    final match = recurrence == 'daily'
        ? DateTimeComponents.time
        : recurrence == 'weekly'
            ? DateTimeComponents.dayOfWeekAndTime
            : recurrence == 'monthly'
                ? DateTimeComponents.dayOfMonthAndTime
                : null;
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final exactAllowed = await android?.canScheduleExactNotifications() ?? false;
    await _plugin.zonedSchedule(
      _id(id),
      title,
      body,
      tz.TZDateTime.from(at, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          // Versioned channel ID: Android does not allow changing sound
          // behaviour on an already-created notification channel.
          'docsgrid_reminders_v3',
          'Document reminders',
          channelDescription: 'Audible local reminders for your documents',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      androidScheduleMode: exactAllowed ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: match,
    );
  }

  Future<void> cancel(String id) async {
    await initialize();
    await _plugin.cancel(_id(id));
  }
}
