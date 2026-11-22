import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'backup_archive_limits.dart';

/// On disk: Full/A001/A001.zip, Full/A001/I001.zip, Full/A001/I002.zip.
/// In the UI: A001, A001/I001, A001/I002.
class BackupChainPlan {
  const BackupChainPlan(this.directory, this.series, this.name, this.parent,
      this.previous);
  final Directory directory;
  final String series;
  final String name;
  final String? parent;
  final Map<String, Map<String, Object?>> previous;
  bool get isFull => parent == null;
  String get label => isFull ? series : series + '/' + name;
  File get output => File(p.join(directory.path, name + '.zip'));
}

class BackupChainUsage {
  const BackupChainUsage(this.name, this.bytes, this.files);
  final String name;
  final int bytes;
  final int files;
}

class BackupChain {
  BackupChain._();
  static final _series = RegExp(r'^A[0-9]{3,}$');
  static final _increment = RegExp(r'^I[0-9]{3,}$');
  static String serial(String prefix, int number) =>
      prefix + number.toString().padLeft(3, '0');

  static Future<Map<String, dynamic>> manifest(File file) async {
    await BackupArchiveLimits.validate(file);
    final stream = InputFileStream(file.path);
    try {
      final zip = ZipDecoder().decodeStream(stream);
      final entry = zip.findFile('manifest.json');
      if (entry == null || !entry.isFile || entry.isSymbolicLink ||
          entry.size > 1024 * 1024) {
        throw StateError('Missing or oversized backup manifest.');
      }
      final result = jsonDecode(utf8.decode(entry.content as List<int>));
      if (result is! Map<String, dynamic> ||
          result['format'] != 'DocsGridBackup' || result['version'] != 1) {
        throw StateError('Unsupported DocsGrid backup.');
      }
      return result;
    } finally {
      stream.closeSync();
    }
  }

  static Map<String, Map<String, Object?>> fingerprints(Map<String, dynamic> m) {
    final raw = m['documentFingerprints'];
    if (raw is! List) {
      throw StateError('Backup fingerprints are missing. Start a new Full series.');
    }
    final found = <String, Map<String, Object?>>{};
    for (final item in raw) {
      if (item is! Map || item['id'] is! String ||
          item['sha256'] is! String || item['sizeBytes'] is! int ||
          item['modifiedMillis'] is! int ||
          !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(item['sha256'] as String) ||
          found.containsKey(item['id'])) {
        throw StateError('Invalid document fingerprint in backup.');
      }
      found[item['id'] as String] = Map<String, Object?>.from(item);
    }
    return found;
  }

  static Future<List<Directory>> folders(Directory root) async {
    if (!await root.exists()) return [];
    final result = <Directory>[];
    await for (final entry in root.list(followLinks: false)) {
      if (entry is Directory && _series.hasMatch(p.basename(entry.path))) {
        result.add(entry);
      }
    }
    result.sort((a,b) => p.basename(a.path).compareTo(p.basename(b.path)));
    return result;
  }

  /// Fail closed on a missing member, an unknown file or a wrong parent.
  static Future<List<File>> verified(Directory folder) async {
    final series = p.basename(folder.path);
    if (!_series.hasMatch(series)) throw StateError('Invalid series name.');
    final items = <File>[];
    await for (final entity in folder.list(followLinks: false)) {
      if (entity is! File) {
        throw StateError('Unknown item in backup chain.');
      }
      final name = p.basenameWithoutExtension(entity.path);
      if (p.extension(entity.path) != '.zip' ||
          (name != series && !_increment.hasMatch(name))) {
        throw StateError('Unknown file in backup chain.');
      }
      items.add(entity);
    }
    items.sort((a,b) {
      final an = p.basenameWithoutExtension(a.path);
      final bn = p.basenameWithoutExtension(b.path);
      if (an == series) return -1;
      if (bn == series) return 1;
      return an.compareTo(bn);
    });
    if (items.isEmpty || p.basename(items.first.path) != series + '.zip') {
      throw StateError('Original Full Backup is missing.');
    }
    var parent = '';
    for (var index = 0; index < items.length; index++) {
      final name = p.basenameWithoutExtension(items[index].path);
      if (name != (index == 0 ? series : serial('I', index))) {
        throw StateError('Missing intermediate incremental backup.');
      }
      final m = await manifest(items[index]);
      if (m['seriesId'] != series || m['backupName'] != name ||
          m['backupType'] != (index == 0 ? 'full' : 'incremental') ||
          m['parentName'] != (index == 0 ? null : parent)) {
        throw StateError('Backup parent relationship is invalid.');
      }
      fingerprints(m);
      parent = name;
    }
    return items;
  }

  static Future<BackupChainPlan> next(
      Directory root, {bool newFull = false}) async {
    final current = await folders(root);
    if (current.isEmpty || newFull) {
      final number = current.isEmpty
          ? 1 : int.parse(p.basename(current.last.path).substring(1)) + 1;
      final series = serial('A', number);
      return BackupChainPlan(Directory(p.join(root.path, series)),
          series, series, null, const {});
    }
    final latest = current.last;
    final members = await verified(latest);
    final previous = await manifest(members.last);
    return BackupChainPlan(
      latest, p.basename(latest.path), serial('I', members.length),
      p.basenameWithoutExtension(members.last.path), fingerprints(previous),
    );
  }

  static Future<List<BackupChainUsage>> usage(Directory root) async {
    final result = <BackupChainUsage>[];
    for (final folder in await folders(root)) {
      var bytes = 0, files = 0;
      await for (final entry in folder.list(followLinks: false)) {
        if (entry is File && p.extension(entry.path) == '.zip') {
          bytes += await entry.length();
          files++;
        }
      }
      result.add(BackupChainUsage(p.basename(folder.path), bytes, files));
    }
    if (await root.exists()) {
      await for (final entry in root.list(followLinks: false)) {
        if (entry is File && p.basename(entry.path).startsWith('DocsGrid_') &&
            p.extension(entry.path) == '.zip') {
          result.add(BackupChainUsage(
            p.basename(entry.path), await entry.length(), 1));
        }
      }
    }
    return result;
  }

  /// The UI only offers whole-series cleanup: never orphan a parent.
  static Future<int> deleteSeries(Directory root, String id) async {
    if (!_series.hasMatch(id)) throw ArgumentError('Invalid series identifier.');
    final folder = Directory(p.join(root.path, id));
    if (!await folder.exists()) throw StateError('Series no longer exists.');
    final items = await verified(folder);
    var freed = 0;
    for (final file in items.reversed) {
      freed += await file.length();
      await file.delete();
    }
    await folder.delete();
    return freed;
  }
}
