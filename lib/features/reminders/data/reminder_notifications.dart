import 'package:flutter/foundation.dart';
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
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    final iosGranted = await ios?.requestPermissions(alert: true, badge: true, sound: true) ?? true;
    return androidGranted && iosGranted;
  }

  /// Stable across app launches and Dart VM processes. String.hashCode is not
  /// a persistence-safe notification identifier.
  @visibleForTesting
  static int notificationIdFor(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash & 0x7fffffff;
  }

  int _id(String id) => notificationIdFor(id);
  int _snoozeId(String id) => notificationIdFor('$id:snooze');

  Future<void> scheduleSnooze({
    required String id,
    required String title,
    String? body,
    required DateTime at,
  }) async {
    await initialize();
    if (!at.isAfter(DateTime.now())) {
      await _plugin.cancel(_snoozeId(id));
      return;
    }
    await _plugin.zonedSchedule(
      _snoozeId(id),
      title,
      body,
      tz.TZDateTime.from(at, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'docsgrid_reminders_v2',
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
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  /// Computes the next local wall-clock occurrence for a reminder.
  /// Monthly repeats retain the chosen day and skip months that lack it.
  @visibleForTesting
  static DateTime? nextScheduledOccurrence({
    required DateTime at,
    required DateTime now,
    String? recurrence,
  }) {
    if (at.isAfter(now)) return at;
    if (recurrence == 'daily') {
      var next = DateTime(now.year, now.month, now.day, at.hour, at.minute, at.second);
      if (!next.isAfter(now)) {
        next = DateTime(now.year, now.month, now.day + 1, at.hour, at.minute, at.second);
      }
      return next;
    }
    if (recurrence == 'weekly') {
      final daysUntil = (at.weekday - now.weekday + 7) % 7;
      var next = DateTime(now.year, now.month, now.day + daysUntil, at.hour, at.minute, at.second);
      if (!next.isAfter(now)) {
        next = DateTime(now.year, now.month, now.day + 7, at.hour, at.minute, at.second);
      }
      return next;
    }
    if (recurrence == 'monthly') {
      var year = now.year;
      var month = now.month;
      while (true) {
        final lastDay = DateTime(year, month + 1, 0).day;
        if (at.day <= lastDay) {
          final candidate = DateTime(year, month, at.day, at.hour, at.minute, at.second);
          if (candidate.isAfter(now)) return candidate;
        }
        month++;
        if (month > 12) { month = 1; year++; }
      }
    }
    return null;
  }

  Future<void> schedule({
    required String id,
    required String title,
    String? body,
    required DateTime at,
    String? recurrence,
  }) async {
    await initialize();
    final scheduledAt = nextScheduledOccurrence(
      at: at,
      now: DateTime.now(),
      recurrence: recurrence,
    );
    if (scheduledAt == null) {
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
    await _plugin.zonedSchedule(
      _id(id),
      title,
      body,
      tz.TZDateTime.from(scheduledAt, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          // Versioned channel ID: Android does not allow changing sound
          // behaviour on an already-created notification channel.
          'docsgrid_reminders_v2',
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
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: match,
    );
  }

  Future<void> cancel(String id) async {
    await initialize();
    await _plugin.cancel(_id(id));
    await _plugin.cancel(_snoozeId(id));
  }
}
