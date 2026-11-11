import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart' as pdfx;

import '../../../core/storage/storage_location_service.dart';

/// Lazily renders and persistently caches the first page of a library PDF.
class DocumentThumbnail extends StatefulWidget {
  const DocumentThumbnail({
    super.key,
    required this.documentId,
    required this.storagePath,
    required this.sizeBytes,
  });

  final String documentId;
  final String storagePath;
  final int sizeBytes;

  @override
  State<DocumentThumbnail> createState() => _DocumentThumbnailState();
}

class _DocumentThumbnailState extends State<DocumentThumbnail> {
  late Future<File?> _thumbnail;

  @override
  void initState() {
    super.initState();
    _thumbnail = _loadThumbnail();
  }

  @override
  void didUpdateWidget(covariant DocumentThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.documentId != widget.documentId ||
        oldWidget.storagePath != widget.storagePath ||
        oldWidget.sizeBytes != widget.sizeBytes) {
      _thumbnail = _loadThumbnail();
    }
  }

  Future<bool> _isValidPng(File file) async {
    try {
      if (!await file.exists() || await file.length() < 8) return false;
      final header = await file.open(mode: FileMode.read).then((handle) async {
        try {
          return await handle.read(8);
        } finally {
          await handle.close();
        }
      });
      const pngSignature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
      for (var i = 0; i < pngSignature.length; i++) {
        if (header[i] != pngSignature[i]) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _removeOldCacheFiles(Directory directory, String prefix,
      {required String keepPath}) async {
    try {
      await for (final entity in directory.list()) {
        if (entity is File &&
            p.basename(entity.path).startsWith(prefix) &&
            entity.path != keepPath) {
          try {
            await entity.delete();
          } catch (_) {
            // A stale cache file must never prevent the current preview.
          }
        }
      }
    } catch (_) {
      // Cache cleanup is best-effort; rendering remains independent of it.
    }
  }

  static const int _thumbnailCacheBudgetBytes = 512 * 1024 * 1024;

  Future<Map<String, String>> _portableThumbnailLocations() async {
    if (!Platform.isAndroid) return const <String, String>{};
    try {
      return await StorageLocationService.instance
          .portableDataLocationsIfAvailable();
    } catch (_) {
      return const <String, String>{};
    }
  }

  Future<Directory> _thumbnailCacheDirectory() async {
    final locations = await _portableThumbnailLocations();
    // New thumbnails go to the dedicated cache area. The old System/Thumbnails
    // directory remains readable as a migration source for existing previews.
    final pagePreviewsUri = locations['pagePreviewsUri'];
    if (pagePreviewsUri != null && pagePreviewsUri.startsWith('file://')) {
      final directory = Directory(Uri.parse(pagePreviewsUri).toFilePath());
      await directory.create(recursive: true);
      return directory;
    }
    final legacyUri = locations['thumbnailsUri'];
    if (legacyUri != null && legacyUri.startsWith('file://')) {
      final directory = Directory(Uri.parse(legacyUri).toFilePath());
      await directory.create(recursive: true);
      return directory;
    }
    // SAF-only or permission-limited providers use the private regenerable cache.
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'docsgrid', 'thumbnails'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<Directory?> _legacyThumbnailCacheDirectory(
    Map<String, String> locations,
    Directory current,
  ) async {
    final uri = locations['thumbnailsUri'];
    if (uri == null || !uri.startsWith('file://')) return null;
    final legacy = Directory(Uri.parse(uri).toFilePath());
    if (p.equals(legacy.path, current.path) || !await legacy.exists()) {
      return null;
    }
    return legacy;
  }

  /// Enforces a soft 512 MiB first-page preview cache using least-recently-used
  /// file timestamps. The preview currently being rendered is never evicted.
  Future<void> _enforceThumbnailCacheBudget(
    Directory directory, {
    required String keepPath,
  }) async {
    try {
      final candidates = <({File file, int bytes, DateTime modified})>[];
      var totalBytes = 0;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File || p.extension(entity.path).toLowerCase() != '.png') {
          continue;
        }
        try {
          final bytes = await entity.length();
          totalBytes += bytes;
          candidates.add((
            file: entity,
            bytes: bytes,
            modified: await entity.lastModified(),
          ));
        } catch (_) {
          // An unreadable cache entry is ignored; it can be regenerated later.
        }
      }
      if (totalBytes <= _thumbnailCacheBudgetBytes) return;
      candidates.sort((a, b) => a.modified.compareTo(b.modified));
      for (final candidate in candidates) {
        if (totalBytes <= _thumbnailCacheBudgetBytes) break;
        if (candidate.file.path == keepPath) continue;
        try {
          await candidate.file.delete();
          totalBytes -= candidate.bytes;
        } catch (_) {
          // Cache cleanup is best-effort and never affects the source PDF.
        }
      }
    } catch (_) {
      // Directory providers and low-storage devices can reject cleanup.
    }
  }

  Future<File?> _loadThumbnail() async {
    final id = widget.documentId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final source = widget.storagePath;
    if (source.isEmpty) return null;

    String pdfPath = source;
    File? staged;
    pdfx.PdfDocument? document;
    pdfx.PdfPage? page;
    try {
      final locations = await _portableThumbnailLocations();
      final directory = await _thumbnailCacheDirectory();
      if (source.startsWith('content://') || source.startsWith('file://')) {
        final temp = await getTemporaryDirectory();
        staged = File(p.join(
          temp.path,
          'thumb_${id}_${DateTime.now().microsecondsSinceEpoch}.pdf',
        ));
        await StorageLocationService.instance.copyPdfToPath(
          sourceUri: source,
          destinationPath: staged.path,
        );
        pdfPath = staged.path;
      } else if (source.startsWith('file:')) {
        pdfPath = Uri.parse(source).toFilePath();
      }

      final pdfFile = File(pdfPath);
      if (!await pdfFile.exists()) return null;

      // Content hash invalidates the preview even when a replacement PDF has
      // the same document ID, path and byte size as the previous file.
      final digest = await sha256.bind(pdfFile.openRead()).first;
      final prefix = '${id}_';
      final cache = File(p.join(
        directory.path,
        '${id}_${widget.sizeBytes}_${digest.toString()}.png',
      ));
      if (!await cache.exists()) {
        final legacy = await _legacyThumbnailCacheDirectory(locations, directory);
        if (legacy != null) {
          final oldCache = File(p.join(legacy.path, p.basename(cache.path)));
          if (await _isValidPng(oldCache)) {
            try {
              await oldCache.copy(cache.path);
            } catch (_) {
              // If migration copy fails, the legacy image is still readable.
            }
          }
        }
      }
      if (await _isValidPng(cache)) {
        try { await cache.setLastModified(DateTime.now()); } catch (_) {}
        await _removeOldCacheFiles(directory, prefix, keepPath: cache.path);
        await _enforceThumbnailCacheBudget(directory, keepPath: cache.path);
        return cache;
      }
      if (await cache.exists()) {
        try {
          await cache.delete();
        } catch (_) {}
      }

      document = await pdfx.PdfDocument.openFile(pdfPath);
      if (document.pagesCount < 1) return null;
      page = await document.getPage(1);
      const width = 240.0;
      final height = (width * page.height / page.width)
          .clamp(160.0, 360.0)
          .toDouble();
      final rendered = await page.render(
        width: width,
        height: height,
        format: pdfx.PdfPageImageFormat.png,
      );
      if (rendered == null || rendered.bytes.isEmpty) return null;

      final partial = File(
        '${cache.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      try {
        await partial.writeAsBytes(rendered.bytes, flush: true);
        if (!await _isValidPng(partial)) return null;
        final saved = await partial.rename(cache.path);
        await _removeOldCacheFiles(directory, prefix, keepPath: saved.path);
        await _enforceThumbnailCacheBudget(directory, keepPath: saved.path);
        return saved;
      } finally {
        try {
          if (await partial.exists()) await partial.delete();
        } catch (_) {}
      }
    } catch (_) {
      return null;
    } finally {
      if (page != null) {
        try {
          await page.close();
        } catch (_) {}
      }
      if (document != null) {
        try {
          await document.close();
        } catch (_) {}
      }
      if (staged != null) {
        try {
          if (await staged.exists()) await staged.delete();
        } catch (_) {}
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _thumbnail,
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (snapshot.connectionState == ConnectionState.done &&
            file != null && file.existsSync()) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              file,
              width: 48,
              height: 64,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _placeholder(context),
            ),
          );
        }
        // Keep a stable red PDF glyph while the first-page preview loads.
        // A spinner here prevents scrollable widget tests from settling and
        // makes large Phone folders visually noisy during thumbnail warm-up.
        return _placeholder(context);
      },
    );
  }

  Widget _placeholder(BuildContext context) =>
      Container(
        width: 48,
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(
          Icons.picture_as_pdf_rounded,
          size: 38,
          color: Color(0xFFD32F2F),
        ),
      );
}
