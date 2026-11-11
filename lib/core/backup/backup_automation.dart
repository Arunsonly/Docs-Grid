import 'dart:convert';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../storage/storage_location_service.dart';
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

    final includePdfs = task == docsGridWeeklyFullBackupTask;
    if (!includePdfs && task != docsGridDailyDatabaseBackupTask) {
      return true;
    }

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

  static Future<void> initializeAndroid() {
    if (!Platform.isAndroid) return Future<void>.value();
    return _initialization ??= _initializeAndroid();
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
      );
    }
    if (!await Workmanager().isScheduledByUniqueName(
      docsGridWeeklyFullBackupTask,
    )) {
      await Workmanager().registerPeriodicTask(
        docsGridWeeklyFullBackupTask,
        docsGridWeeklyFullBackupTask,
        frequency: const Duration(days: 7),
      );
    }
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

  /// Runs due backups while the Activity/native storage bridge is available.
  /// This is also the safe fallback for SAF-backed PDFs skipped by a headless worker.
  static Future<void> runDueForegroundBackups() async {
    if (!Platform.isAndroid) return;
    final storage = StorageLocationService.instance;
    try {
      final locations = await storage.portableDataLocationsIfAvailable();
      final databaseUri = locations['databaseBackupsUri'] ?? locations['backupsUri'];
      final fullUri = locations['fullBackupsUri'] ?? locations['backupsUri'];
      // SAF-only trees can still use metadata snapshots and restore existing
      // PDFs in place, but ZIP publishing requires a file-backed destination.
      if (databaseUri == null || !databaseUri.startsWith('file://') ||
          fullUri == null || !fullUri.startsWith('file://')) {
        return;
      }

      final now = DateTime.now().toUtc();
      final daily = await readStatus(full: false);
      final dailySuccess = DateTime.tryParse(
        daily['completedAtUtc'] as String? ?? '',
      );
      if (dailySuccess == null ||
          now.difference(dailySuccess) >= const Duration(hours: 24)) {
        await _runForegroundBackup(includePdfs: false);
      }

      final weekly = await readStatus(full: true);
      final weeklySuccess = DateTime.tryParse(
        weekly['completedAtUtc'] as String? ?? '',
      );
      if (weeklySuccess == null ||
          now.difference(weeklySuccess) >= const Duration(days: 7)) {
        await _runForegroundBackup(includePdfs: true);
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
