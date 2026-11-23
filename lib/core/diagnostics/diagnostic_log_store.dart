import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../storage/storage_location_service.dart';

/// Small, local-only, bounded diagnostic journal.
/// The private copy works without Android storage permission; when the
/// portable System/Logs location is available, entries are mirrored there.
/// Logs never contain PDF bytes, document names or raw filesystem URIs.
class DiagnosticLogStore {
  DiagnosticLogStore._(this._privateDirectory, this._portableDirectory);

  static final DiagnosticLogStore instance = DiagnosticLogStore._(
    _defaultPrivateDirectory, _defaultPortableDirectory,
  );

  /// Does not touch platform plugins; safe for deterministic file tests.
  DiagnosticLogStore.forTesting({
    required Directory privateDirectory,
    Directory? portableDirectory,
  }) : this._(
    (() async => privateDirectory),
    (() async => portableDirectory),
  );

  static const int maxFileBytes = 256 * 1024;
  static const int maxLogFiles = 20;
  static const int daysToKeep = 14;
  final Future<Directory> Function() _privateDirectory;
  final Future<Directory?> Function() _portableDirectory;
  Future<void> _writes = Future<void>.value();

  static Future<Directory> _defaultPrivateDirectory() async {
    final app = await getApplicationSupportDirectory();
    return Directory(p.join(app.path, 'DocsGrid', 'Logs'));
  }

  static Future<Directory?> _defaultPortableDirectory() async {
    if (!Platform.isAndroid) return null;
    try {
      final storage = StorageLocationService.instance;
      var locations = await storage.cachedPortableDataLocations();
      if (locations['logsUri'] == null) {
        locations = await storage.portableDataLocationsIfAvailable();
      }
      final uri = locations['logsUri'];
      if (uri == null || !uri.startsWith('file://')) return null;
      final directory = Directory(Uri.parse(uri).toFilePath());
      // Do not silently create or change the user's selected SAF tree.
      return await directory.exists() ? directory : null;
    } catch (_) {
      // Private logging must work even when portable storage is inaccessible.
      return null;
    }
  }

  /// Keep actionable error categories but redact user content from provider
  /// messages. These are diagnostic hints, not an export of stack traces.
  static String redact(Object error) {
    final raw = error is PlatformException
        ? '${error.code}: ${error.message ?? 'Storage operation failed'}'
        : error.toString();
    var value = raw.replaceAll(RegExp(r'[\r\n\t]+'), ' ');
    value = value.replaceAll(
        RegExp(r'(?:content|file)://[^\s,;]+', caseSensitive: false),
        '[storage URI]');
    value = value.replaceAll(
        RegExp(r'/(?:storage|data|mnt|sdcard|emulated|Android)/[^\s,;]+',
            caseSensitive: false), '[storage path]');
    value = value.replaceAll(
        RegExp(r'\b[^\s/\\,:;]+\.(?:pdf|zip|jpg|jpeg|png|db|sqlite)\b',
            caseSensitive: false), '[file]');
    value = value.replaceAll(RegExp(r"'[^']{1,200}'"), '[item]');
    value = value.replaceAll(RegExp(r'"[^"]{1,200}"'), '[item]');
    value = value.replaceAll(RegExp(r'\b\d{10,}\b'), '[number]');
    value = value.replaceAll(
        RegExp(r'\b(?:Bearer|token|password|secret|api[_-]?key)\s*[:=]?\s*[^\s,;]+',
            caseSensitive: false), '[credential]');
    return value.length > 300 ? '${value.substring(0, 300)}…' : value;
  }

  static String _safeOperation(String operation) {
    final cleaned = operation.replaceAll(RegExp(r'[^a-zA-Z0-9 _./-]'), '_');
    return cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
  }

  Future<void> recordError(String operation, Object error,
      {int occurrences = 1}) =>
      recordMessage(operation, redact(error), occurrences: occurrences);

  Future<void> recordMessage(String operation, String message,
      {int occurrences = 1}) {
    if (occurrences < 1) return Future<void>.value();
    final description = redact(message);
    final line = '${DateTime.now().toUtc().toIso8601String()} | '
        'ERROR | ${_safeOperation(operation)} | count=$occurrences | '
        '$description\n';
    // All writes, even from concurrent async UI callbacks, are serialized.
    // A logging failure must not turn a successful restore into a failed one.
    _writes = _writes.then((_) async {
      try {
        final local = await _privateDirectory();
        await _append(local, line);
      } catch (_) {
        // Optional external logging is still attempted.
      }
      try {
        final portable = await _portableDirectory();
        if (portable != null) await _append(portable, line);
      } catch (_) {
        // Missing/ungranted shared storage never breaks the user's task.
      }
    });
    return _writes;
  }

  static Future<void> _append(Directory directory, String line) async {
    await directory.create(recursive: true);
    final day = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    final bytes = line.codeUnits.length;
    for (var index = 0; index < 60; index++) {
      final suffix = index == 0 ? '' : '-${index.toString().padLeft(2, '0')}';
      final file = File(p.join(directory.path, 'docsgrid-errors-$day$suffix.log'));
      final size = await file.exists() ? await file.length() : 0;
      if (size + bytes > maxFileBytes) continue;
      await file.writeAsString(line, mode: FileMode.append, flush: true);
      break;
    }
    await _trim(directory);
  }

  static Future<List<File>> _journalFiles(Directory directory) async {
    if (!await directory.exists()) return const <File>[];
    final entries = await directory.list(followLinks: false)
        .where((e) => e is File &&
            RegExp(r'^docsgrid-errors-\d{4}-\d{2}-\d{2}(?:-\d{2})?\.log$')
                .hasMatch(p.basename(e.path)))
        .cast<File>().toList();
    entries.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    return entries;
  }

  static Future<void> _trim(Directory directory) async {
    final files = await _journalFiles(directory);
    final cutoff = DateTime.now().toUtc().subtract(const Duration(days: daysToKeep));
    final keep = <File>[];
    for (final file in files) {
      final name = p.basename(file.path);
      final day = DateTime.tryParse(name.substring(16, 26));
      if (day != null && day.isBefore(DateTime.utc(
          cutoff.year, cutoff.month, cutoff.day))) {
        await file.delete();
      } else {
        keep.add(file);
      }
    }
    for (final file in keep.take(keep.length > maxLogFiles
        ? keep.length - maxLogFiles : 0)) {
      await file.delete();
    }
  }

  /// Read-only; combines private and portable entries without double-counting
  /// mirrored lines. UI displays the most recent 150 events.
  Future<DiagnosticLogSnapshot> readRecent() async {
    await _writes;
    final all = <String>{};
    var portableAvailable = false;
    for (final resolver in <Future<Directory?> Function()>[
      () async => await _privateDirectory(), _portableDirectory,
    ]) {
      try {
        final directory = await resolver();
        if (directory == null) continue;
        final files = await _journalFiles(directory);
        for (final file in files.reversed.take(4)) {
          final size = await file.length();
          if (size > maxFileBytes) continue;
          final lines = await file.readAsLines();
          all.addAll(lines);
        }
      } catch (_) {
        // A revoked provider grant must not block reading private entries.
      }
    }
    try {
      portableAvailable = await _portableDirectory() != null;
    } catch (_) {}
    final sorted = all.toList()..sort();
    return DiagnosticLogSnapshot(
      text: sorted.isEmpty
          ? 'No saved errors yet.'
          : sorted.reversed.take(150).join('\n'),
      portableAvailable: portableAvailable,
      eventCount: sorted.length,
    );
  }
}

class DiagnosticLogSnapshot {
  const DiagnosticLogSnapshot({
    required this.text,
    required this.portableAvailable,
    required this.eventCount,
  });
  final String text;
  final bool portableAvailable;
  final int eventCount;
}
