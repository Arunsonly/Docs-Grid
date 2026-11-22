import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';

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

  /// Rebuild the *selected point in time* as a temporary, bounded Full ZIP.
  /// Existing restore safety checks then process this archive unchanged.
  /// No original series file or user's live PDF is modified.
  static Future<File> compose(File selected, Directory tempRoot) async {
    final name = p.basenameWithoutExtension(selected.path);
    if (!_increment.hasMatch(name)) {
      throw StateError('Select an incremental backup (I001, I002, ...).');
    }
    final chain = await verified(selected.parent);
    final index = chain.indexWhere((item) =>
        p.normalize(item.path) == p.normalize(selected.path));
    if (index < 1) {
      throw StateError('Restore needs the original A-series folder and parents.');
    }

    final working = await tempRoot.createTemp('docsgrid_chain_restore_');
    final payloads = <String, File>{};
    final checksums = <String, String>{};
    final displayNames = <String, String>{};
    final metadata = <String, File>{};
    Map<String, dynamic>? latest;
    try {
      for (final file in chain.take(index + 1)) {
        final input = InputFileStream(file.path);
        try {
          final archive = ZipDecoder().decodeStream(input);
          final manifestEntry = archive.findFile('manifest.json');
          if (manifestEntry == null || manifestEntry.size > 1024 * 1024) {
            throw StateError('The incremental manifest is missing.');
          }
          final m = jsonDecode(utf8.decode(manifestEntry.content as List<int>))
              as Map<String, dynamic>;
          latest = m;
          final pdfRecords = m['files'];
          final metadataRecords = m['metadataFiles'];
          if (pdfRecords is! List || metadataRecords is! List) {
            throw StateError('The incremental archive is incomplete.');
          }
          final seen = <String>{};
          for (final record in pdfRecords) {
            if (record is! Map ||
                record['documentId'] is! String ||
                record['entry'] is! String ||
                record['sha256'] is! String ||
                !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(record['sha256'] as String)) {
              throw StateError('Invalid incremental PDF manifest.');
            }
            final id = record['documentId'] as String;
            final entryName = record['entry'] as String;
            if (!seen.add(id) || !entryName.startsWith('pdfs/') ||
                entryName.split('/').any((part) =>
                    part.isEmpty || part == '.' || part == '..')) {
              throw StateError('Unsafe or duplicate incremental entry.');
            }
            final entry = archive.findFile(entryName);
            if (entry == null || !entry.isFile || entry.isSymbolicLink) {
              throw StateError('An incremental PDF payload is missing.');
            }
            final token = sha256.convert(utf8.encode(id)).toString();
            final target = File(p.join(working.path, token + '.pdf'));
            final output = OutputFileStream(target.path);
            try {
              entry.writeContent(output);
            } finally {
              output.closeSync();
            }
            final digest = (await sha256.bind(target.openRead()).first).toString();
            if (digest != (record['sha256'] as String).toLowerCase()) {
              throw StateError('An incremental PDF failed SHA-256 verification.');
            }
            payloads[id] = target;
            checksums[id] = digest;
            displayNames[id] = record['originalName'] as String? ?? id + '.pdf';
          }
          // Each Incremental contains a complete *metadata* snapshot, but only
          // new or modified PDF bytes. The latest snapshot governs restore.
          for (final record in metadataRecords) {
            if (record is! Map || record['entry'] is! String ||
                record['sizeBytes'] is! int || record['sha256'] is! String) {
              throw StateError('Invalid incremental metadata record.');
            }
            final name = record['entry'] as String;
            if (name.contains('/') || !name.endsWith('.json')) {
              throw StateError('Unsafe incremental metadata filename.');
            }
            final entry = archive.findFile(name);
            if (entry == null || !entry.isFile || entry.isSymbolicLink ||
                entry.size > 64 * 1024 * 1024) {
              throw StateError('Missing or oversized incremental metadata.');
            }
            final target = File(p.join(working.path, name));
            await target.writeAsBytes(entry.content as List<int>, flush: true);
            if (await target.length() != record['sizeBytes'] ||
                (await sha256.bind(target.openRead()).first).toString() !=
                    (record['sha256'] as String).toLowerCase()) {
              throw StateError('Incremental metadata checksum mismatch.');
            }
            metadata[name] = target;
          }
        } finally {
          input.closeSync();
        }
      }

      final docFile = metadata['documents.json'];
      if (docFile == null) throw StateError('Missing document metadata.');
      final decodedDocs = jsonDecode(await docFile.readAsString());
      if (decodedDocs is! List) throw StateError('Invalid document metadata.');
      final composedFiles = <Map<String, Object?>>[];
      final seenIds = <String>{};
      for (final row in decodedDocs) {
        if (row is! Map || row['id'] is! String ||
            !seenIds.add(row['id'] as String) ||
            row['sha256'] is! String) {
          throw StateError('Invalid or duplicate document record.');
        }
        final id = row['id'] as String;
        if (payloads[id] == null ||
            checksums[id] != (row['sha256'] as String).toLowerCase()) {
          throw StateError('A PDF or parent backup is missing for document ' + id);
        }
        composedFiles.add({
          'documentId': id,
          'entry': 'pdfs/' + sha256.convert(utf8.encode(id)).toString() + '.pdf',
          'sha256': checksums[id],
          'originalName': displayNames[id],
        });
      }
      // Prevent writing an archive larger than the agreed 2 GB policy.
      var expectedSize = 0;
      for (final entry in composedFiles) {
        expectedSize += await payloads[entry['documentId']]!.length();
      }
      for (final file in metadata.values) {
        expectedSize += await file.length();
      }
      if (expectedSize >= BackupArchiveLimits.maxArchiveBytes) {
        throw StateError('The reconstructed Full Backup exceeds 2 GB.');
      }

      final outputFile = File(p.join(working.path, 'composed_full.zip'));
      final encoder = ZipFileEncoder();
      encoder.create(outputFile.path);
      Future<void> add(File source, String entry) async {
        final input = InputFileStream(source.path);
        try {
          encoder.addArchiveFile(ArchiveFile.stream(entry, input)
            ..compression = CompressionType.none);
        } finally {
          await input.close();
        }
      }
      try {
        for (final entry in metadata.entries) {
          await add(entry.value, entry.key);
        }
        for (final entry in composedFiles) {
          await add(payloads[entry['documentId']]!, entry['entry'] as String);
        }
        final m = <String, dynamic>{
          ...latest!,
          'backupType': 'full',
          'backupId': latest['backupId'],
          'files': composedFiles,
          'parentName': null,
        };
        final manifestFile = File(p.join(working.path, 'manifest.json'));
        await manifestFile.writeAsString(jsonEncode(m), flush: true);
        await add(manifestFile, 'manifest.json');
      } finally {
        await encoder.close();
      }
      await BackupArchiveLimits.validate(outputFile);
      return outputFile;
    } catch (_) {
      try { await working.delete(recursive: true); } catch (_) {}
      rethrow;
    }
  }
}
