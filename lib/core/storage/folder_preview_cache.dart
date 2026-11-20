import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A read-only screen preview, never a source of truth for file operations.
/// It deliberately stores no PDF bytes, filesystem path, content URI or ID.
class FolderPreviewItem {
  const FolderPreviewItem({
    required this.name,
    required this.isFolder,
    this.pdfCount = 0,
    this.sizeBytes = 0,
  });

  final String name;
  final bool isFolder;
  final int pdfCount;
  final int sizeBytes;

  Map<String, Object?> toJson() => {
    'name': name,
    'isFolder': isFolder,
    'pdfCount': pdfCount,
    'sizeBytes': sizeBytes,
  };

  static FolderPreviewItem? fromJson(Object? value) {
    if (value is! Map || value['name'] is! String ||
        value['isFolder'] is! bool) return null;
    final name = value['name'] as String;
    if (name.isEmpty || name.length > 512) return null;
    return FolderPreviewItem(
      name: name,
      isFolder: value['isFolder'] as bool,
      pdfCount: ((value['pdfCount'] as num?)?.toInt() ?? 0).clamp(0, 10000000).toInt(),
      sizeBytes: ((value['sizeBytes'] as num?)?.toInt() ?? 0).clamp(0, 1 << 62).toInt(),
    );
  }
}

class FolderPreview {
  const FolderPreview({
    required this.key,
    required this.items,
    required this.savedAt,
    this.totalPdfCount,
    this.totalFolderCount,
  });

  final String key;
  final List<FolderPreviewItem> items;
  final DateTime savedAt;
  /// Total PDFs verified by SQLite, even if only a first page is previewed.
  final int? totalPdfCount;
  /// Exact SQLite count when a speculative preview contains only a few rows.
  final int? totalFolderCount;

  int get folderCount => items.where((item) => item.isFolder).length;
  int get pdfCount => items.where((item) => !item.isFolder).length;

  Map<String, Object?> toJson() => {
    'schema': 2,
    'keyHash': _previewKeyHash(key),
    'savedAt': savedAt.toUtc().toIso8601String(),
    if (totalPdfCount != null) 'totalPdfCount': totalPdfCount,
    if (totalFolderCount != null) 'totalFolderCount': totalFolderCount,
    'items': items.map((item) => item.toJson()).toList(growable: false),
  };

  /// Also used by unit tests for corrupt and mismatched cache files.
  static FolderPreview? fromJson(Object? raw, String expectedKey) {
    if (raw is! Map || raw['schema'] != 2 ||
        raw['keyHash'] != _previewKeyHash(expectedKey) ||
        raw['items'] is! List ||
        raw['savedAt'] is! String) return null;
    final savedAt = DateTime.tryParse(raw['savedAt'] as String);
    if (savedAt == null || savedAt.isAfter(DateTime.now().add(const Duration(minutes: 5))) ||
        DateTime.now().difference(savedAt) > const Duration(days: 30)) {
      return null;
    }
    final values = raw['items'] as List;
    if (values.length > FolderPreviewCache.maxItemsPerFolder) return null;
    final items = <FolderPreviewItem>[];
    for (final value in values) {
      final parsed = FolderPreviewItem.fromJson(value);
      if (parsed == null) return null;
      items.add(parsed);
    }
    return FolderPreview(
      key: expectedKey,
      items: List<FolderPreviewItem>.unmodifiable(items),
      savedAt: savedAt,
      totalPdfCount: raw['totalPdfCount'] is int &&
          (raw['totalPdfCount'] as int) >=
              items.where((item) => !item.isFolder).length &&
          (raw['totalPdfCount'] as int) <= 10000000
          ? raw['totalPdfCount'] as int : null,
      totalFolderCount: raw['totalFolderCount'] is int &&
          (raw['totalFolderCount'] as int) >=
              items.where((item) => item.isFolder).length &&
          (raw['totalFolderCount'] as int) <= 10000000
          ? raw['totalFolderCount'] as int : null,
    );
  }
}

String _previewKeyHash(String key) => sha256.convert(utf8.encode(key)).toString();

Object? _decodePreviewJson(String contents) => jsonDecode(contents);
String _encodePreviewJson(Map<String, Object?> payload) => jsonEncode(payload);

/// Per-folder, bounded, app-private metadata. A cache failure must never
/// interrupt real SQLite/MediaStore/SAF reads or modify original PDFs.
class FolderPreviewCache {
  FolderPreviewCache._();

  static const int maxItemsPerFolder = 15000;
  static const int maxFileBytes = 5 * 1024 * 1024;
  static const int maxSavedFolders = 96;
  static const int maxTotalBytes = 32 * 1024 * 1024;

  static String gridKey(String? folderId) => 'grid:${folderId ?? '__root__'}';

  /// The root signature prevents showing metadata from another mounted SAF
  /// tree or a different Phone storage configuration.
  static String phoneKey(String rootSignature, String folderPath) =>
      'phone:$rootSignature:$folderPath';

  static Future<Directory> _directory() async {
    final root = await getApplicationSupportDirectory();
    final dir = Directory(p.join(root.path, 'docsgrid_folder_previews_v1'));
    await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _fileFor(String key) async {
    final dir = await _directory();
    final hash = _previewKeyHash(key);
    return File(p.join(dir.path, '$hash.json'));
  }

  static Future<FolderPreview?> read(String key) async {
    try {
      final file = await _fileFor(key);
      if (!await file.exists() || await file.length() > maxFileBytes) return null;
      final decoded = await compute(_decodePreviewJson, await file.readAsString());
      return FolderPreview.fromJson(decoded, key);
    } catch (_) {
      // Missing/corrupt/permission-restricted previews are cache misses.
      return null;
    }
  }

  static Future<void> write(FolderPreview preview) async {
    if (preview.items.length > maxItemsPerFolder ||
        preview.key.isEmpty) return;
    File? temporary;
    try {
      final file = await _fileFor(preview.key);
      final payload = await compute(_encodePreviewJson, preview.toJson());
      if (utf8.encode(payload).length > maxFileBytes) return;
      temporary = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.writing');
      await temporary.writeAsString(payload, flush: true);
      // Same-directory rename makes completed previews visible atomically.
      await temporary.rename(file.path);
      await _prune();
    } catch (_) {
      // Only optional metadata is lost. Original PDFs and DB are untouched.
    } finally {
      try {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
      } catch (_) {}
    }
  }

  static Future<void> _prune() async {
    try {
      final dir = await _directory();
      final files = await dir.list(followLinks: false)
          .where((entry) => entry is File && entry.path.endsWith('.json'))
          .cast<File>()
          .toList();
      final ages = await Future.wait(files.map((file) async {
        final stat = await file.stat();
        return (file: file, stamp: stat.modified, bytes: stat.size);
      }));
      ages.sort((a, b) => b.stamp.compareTo(a.stamp));
      var kept = 0;
      var storedBytes = 0;
      for (final entry in ages) {
        if (kept < maxSavedFolders &&
            storedBytes + entry.bytes <= maxTotalBytes) {
          kept++;
          storedBytes += entry.bytes;
        } else {
          // Only files from the dedicated hashed preview directory.
          try { await entry.file.delete(); } catch (_) {}
        }
      }
    } catch (_) {}
  }
}
