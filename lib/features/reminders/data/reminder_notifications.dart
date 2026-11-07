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
    // Some Android builds report the legacy IANA alias Asia/Calcutta.
    // The bundled timezone database exposes Asia/Kolkata as the canonical ID.
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
      // Scheduling should remain available even if a vendor returns an
      // unknown timezone alias; UTC is safer than crashing the reminder UI.
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
            : null;
    await _plugin.zonedSchedule(
      _id(id),
      title,
      body,
      tz.TZDateTime.from(at, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'docsgrid_reminders',
          'Document reminders',
          channelDescription: 'Local reminders for your documents',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: match,
    );
  }

  Future<void> cancel(String id) async {
    await initialize();
    await _plugin.cancel(_id(id));
  }
}
