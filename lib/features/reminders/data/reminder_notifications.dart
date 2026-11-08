import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Device-local notification scheduler. Reminder contents remain on-device.
class ReminderNotifications {
  ReminderNotifications._();
  static final ReminderNotifications instance = ReminderNotifications._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static const MethodChannel _settingsChannel = MethodChannel('docsgrid/notifications');
  bool _ready = false;

  static void Function(String documentId)? onDocumentNotificationTap;
  static String? _pendingDocumentId;

  static void queueDocumentTap(String documentId) {
    if (documentId.isNotEmpty) _pendingDocumentId = documentId;
  }

  static String? takePendingDocumentId() {
    final value = _pendingDocumentId;
    _pendingDocumentId = null;
    return value;
  }

  static void _dispatchDocumentTap(String? payload) {
    if (payload == null || payload.isEmpty) return;
    final handler = onDocumentNotificationTap;
    if (handler == null) {
      _pendingDocumentId = payload;
    } else {
      handler(payload);
    }
  }

  Future<void> initialize() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    try {
      final deviceTimeZone = await FlutterTimezone.getLocalTimezone();
      // Android vendors may still report legacy IANA aliases.
      final reportedId = deviceTimeZone.identifier;
      final canonicalId = switch (reportedId) {
        'Asia/Calcutta' => 'Asia/Kolkata',
        'Asia/Katmandu' => 'Asia/Kathmandu',
        'Asia/Rangoon' => 'Asia/Yangon',
        _ => reportedId,
      };
      tz.setLocalLocation(tz.getLocation(canonicalId));
    } catch (_) {
      // Timezone plugins can fail on vendor ROMs. Keep reminder setup usable
      // rather than preventing the rest of the app from opening.
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
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) {
        _dispatchDocumentTap(response.payload);
      },
    );
    _ready = true;
    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp == true) {
      _dispatchDocumentTap(launchDetails?.notificationResponse?.payload);
    }
  }

  Future<bool> requestPermission() async {
    await initialize();
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final androidGranted = await android?.requestNotificationsPermission() ?? true;
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    final iosGranted = await ios?.requestPermissions(alert: true, badge: true, sound: true) ?? true;
    return androidGranted && iosGranted;
  }

  Future<bool> areNotificationsEnabled() async {
    await initialize();
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final androidEnabled = await android?.areNotificationsEnabled() ?? true;
    if (!androidEnabled) return false;
    final channels = await android?.getNotificationChannels();
    if (channels != null) {
      final reminderChannel = channels.where((channel) => channel.id == 'docsgrid_reminders_v3');
      if (reminderChannel.isNotEmpty && reminderChannel.first.importance == Importance.none) {
        return false;
      }
    }
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    final permissions = await ios?.checkPermissions();
    return permissions?.isEnabled ?? true;
  }

  Future<void> openNotificationSettings() async {
    await _settingsChannel.invokeMethod<void>('openSettings');
  }

  /// Stable across app launches; String.hashCode is not a persistence contract.
  static int stableNotificationId(String id) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(id)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash & 0x7fffffff;
  }

  int _id(String id) => stableNotificationId(id);

  /// Computes the next wall-clock occurrence without changing the stored
  /// original date. This keeps daily/weekly reminders alive after their first
  /// occurrence when the app is reopened or the device timezone changes.
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
      var next = DateTime(
        now.year, now.month, now.day + daysUntil,
        at.hour, at.minute, at.second,
      );
      if (!next.isAfter(now)) {
        next = DateTime(now.year, now.month, now.day + 7, at.hour, at.minute, at.second);
      }
      return next;
    }
    return null;
  }

  /// Reconciles OS pending notifications with the SQLite source of truth.
  /// It never requests permission; denied notifications do not block the app.
  Future<void> reconcile(List<Map<String, Object?>> reminders) async {
    await initialize();
    final activeIds = <int>{};
    for (final row in reminders) {
      if ((row['enabled'] as int? ?? 0) != 1 ||
          row['status'] == 'completed' || row['status'] == 'cancelled') {
        continue;
      }
      final at = DateTime.parse(row['remind_at_utc'] as String).toLocal();
      final recurrence = row['recurrence_rule'] as String?;
      if (nextScheduledOccurrence(
            at: at, now: DateTime.now(), recurrence: recurrence,
          ) != null) {
        activeIds.add(_id(row['id'] as String));
      }
    }
    final pending = await _plugin.pendingNotificationRequests();
    for (final request in pending) {
      if (!activeIds.contains(request.id)) {
        await _plugin.cancel(request.id);
      }
    }
    for (final row in reminders) {
      if ((row['enabled'] as int? ?? 0) != 1 ||
          row['status'] == 'completed' || row['status'] == 'cancelled') {
        continue;
      }
      try {
        await schedule(
          id: row['id'] as String,
          title: row['title'] as String,
          body: row['note'] as String?,
          at: DateTime.parse(row['remind_at_utc'] as String).toLocal(),
          recurrence: row['recurrence_rule'] as String?,
          documentId: row['document_id'] as String?,
        );
      } catch (_) {
        // Keep the database reminder even if the OS refuses this schedule.
      }
    }
  }

  Future<void> schedule({
    required String id,
    required String title,
    String? body,
    required DateTime at,
    String? recurrence,
    String? documentId,
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
      // Document reminders do not need minute-level precision. Inexact scheduling
      // avoids the restricted exact-alarm special access and its settings prompt.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: match,
      payload: documentId,
    );
  }

  Future<void> cancel(String id) async {
    await initialize();
    await _plugin.cancel(_id(id));
  }
}
