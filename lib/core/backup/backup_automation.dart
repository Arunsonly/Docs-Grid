import 'dart:convert';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../storage/storage_location_service.dart';
import '../database/app_database.dart';
import '../../features/tools/document_tools_service.dart';

const String docsGridDailyDatabaseBackupTask =
    'docsgrid.daily_database_backup';
const String docsGridWeeklyFullBackupTask = 'docsgrid.weekly_full_backup';

const String _dailyStatusKey = 'docsgrid_backup_daily_status_v1';
const String _weeklyStatusKey = 'docsgrid_backup_weekly_status_v1';

@pragma('vm:entry-point')
void docsGridBackgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    // Full PDF archives are user-initiated only. Ignore legacy queued work.
    if (task != docsGridDailyDatabaseBackupTask) return true;
    const includePdfs = false;

    final prefs = await SharedPreferences.getInstance();
    final statusKey = includePdfs ? _weeklyStatusKey : _dailyStatusKey;
    final attemptedAt = DateTime.now().toUtc().toIso8601String();
    try {
      final locations = await StorageLocationService.instance
          .cachedPortableDataLocations();
      final destination = includePdfs
          ? (locations['fullBackupsUri'] ?? locations['backupsUri'])
          : (locations['databaseBackupsUri'] ?? locations['backupsUri']);
      if (destination == null || !destination.startsWith('file://')) {
        await prefs.setString(statusKey, jsonEncode({
          'status': 'needs_foreground_setup',
          'attemptedAtUtc': attemptedAt,
          'message': 'Open DocsGrid with storage access to initialize its portable backup folders.',
        }));
        return true;
      }

      final archive = await DocumentToolsService().createBackup(
        includePdfs: includePdfs,
        backgroundSafe: true,
      );
      await prefs.setString(statusKey, jsonEncode({
        'status': 'success',
        'attemptedAtUtc': attemptedAt,
        'completedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'archiveName': archive.uri.pathSegments.isEmpty
            ? archive.path
            : archive.uri.pathSegments.last,
        'archiveBytes': await archive.length(),
      }));
      return true;
    } catch (error) {
      final message = error.toString();
      await prefs.setString(statusKey, jsonEncode({
        'status': 'needs_foreground_retry',
        'attemptedAtUtc': attemptedAt,
        'message': message,
      }));
      // SAF content URIs need the Activity's native ContentResolver channel.
      // The next foreground pass retries with the full storage permission.
      if (message.contains('SAF content URI') ||
          message.contains('portable file-backed backup folder')) {
        return true;
      }
      return false;
    }
  });
}

class BackupAutomation {
  BackupAutomation._();

  static Future<void>? _initialization;

  static Future<void> initializeAndroid() async {
    if (!Platform.isAndroid) return;
    try {
      await (_initialization ??= _initializeAndroid());
    } catch (_) {
      // Work scheduling is opportunistic and must never block app startup.
      _initialization = null;
    }
  }

  static Future<void> _initializeAndroid() async {
    await Workmanager().initialize(docsGridBackgroundDispatcher);

    if (!await Workmanager().isScheduledByUniqueName(
      docsGridDailyDatabaseBackupTask,
    )) {
      await Workmanager().registerPeriodicTask(
        docsGridDailyDatabaseBackupTask,
        docsGridDailyDatabaseBackupTask,
        frequency: const Duration(hours: 24),
        constraints: Constraints(
          requiresBatteryNotLow: true,
          requiresStorageNotLow: true,
        ),
      );
    }
    // Remove the periodic Full task that earlier DocsGrid versions registered.
    // This is idempotent; manual Full/Incremental backups are never scheduled.
    await Workmanager().cancelByUniqueName(docsGridWeeklyFullBackupTask);
  }

  static Future<Map<String, Object?>> readStatus({required bool full}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(full ? _weeklyStatusKey : _dailyStatusKey);
    if (raw == null) return const <String, Object?>{'status': 'not_run'};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? Map<String, Object?>.from(decoded)
          : const <String, Object?>{'status': 'unknown'};
    } catch (_) {
      return const <String, Object?>{'status': 'unknown'};
    }
  }

  /// A failed/unsupported task is retried with backoff instead of repeating
  /// a large archive on every Activity resume.
  static bool isBackupDue({
    required Map<String, Object?> status,
    required DateTime now,
    required Duration interval,
    required Duration retryCooldown,
  }) {
    final completed = DateTime.tryParse(status['completedAtUtc'] as String? ?? '');
    if (completed != null && now.difference(completed) < interval) return false;
    final attempted = DateTime.tryParse(status['attemptedAtUtc'] as String? ?? '');
    if (attempted != null && now.difference(attempted) < retryCooldown) return false;
    return true;
  }

  /// Runs due backups while the Activity/native storage bridge is available.
  /// This is also the safe fallback for SAF-backed PDFs skipped by a headless worker.
  static Future<void> runDueForegroundBackups() async {
    if (!Platform.isAndroid) return;
    // Do not create a meaningless 3–4 KB database ZIP on a fresh install.
    // The first scheduled backup begins after the user has stored real data.
    if (!await AppDatabase.instance.hasPortableUserData()) return;
    final storage = StorageLocationService.instance;
    try {
      final locations = await storage.portableDataLocationsIfAvailable();
      final databaseUri = locations['databaseBackupsUri'] ?? locations['backupsUri'];
      // Scheduled backups never need access to the user's PDF backup folder.
      if (databaseUri == null) return;

      final now = DateTime.now().toUtc();
      final daily = await readStatus(full: false);
      if (isBackupDue(
        status: daily,
        now: now,
        interval: const Duration(hours: 24),
        retryCooldown: const Duration(hours: 6),
      )) {
        await _runForegroundBackup(includePdfs: false);
      }

    } catch (_) {
      // User PDF access remains usable when backup storage is unavailable.
    }
  }

  static Future<void> _runForegroundBackup({required bool includePdfs}) async {
    final prefs = await SharedPreferences.getInstance();
    final key = includePdfs ? _weeklyStatusKey : _dailyStatusKey;
    final attemptedAt = DateTime.now().toUtc().toIso8601String();
    try {
      final archive = await DocumentToolsService().createBackup(
        includePdfs: includePdfs,
      );
      await prefs.setString(key, jsonEncode({
        'status': 'success',
        'attemptedAtUtc': attemptedAt,
        'completedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'archiveName': archive.uri.pathSegments.isEmpty
            ? archive.path
            : archive.uri.pathSegments.last,
        'archiveBytes': await archive.length(),
      }));
    } catch (error) {
      await prefs.setString(key, jsonEncode({
        'status': 'failed',
        'attemptedAtUtc': attemptedAt,
        'message': error.toString(),
      }));
    }
  }
}
