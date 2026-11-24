import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart' as pdfx;

import '../../../core/storage/storage_location_service.dart';

// Bound on-disk cache names even for very long Phone content URIs.
String _thumbnailIdentity(String documentId, String storagePath) =>
    sha256.convert(utf8.encode(jsonEncode([documentId, storagePath])))
        .toString().substring(0, 32);

@visibleForTesting
String thumbnailCacheFileName({
  required String documentId,
  required String storagePath,
  required int sizeBytes,
  required String fingerprint,
}) {
  final identity = _thumbnailIdentity(documentId, storagePath);
  final revision = sha256.convert(utf8.encode(fingerprint)).toString().substring(0, 32);
  return '${identity}_${sizeBytes}_${revision}.png';
}

// Keep SAF, MediaStore, and shared-storage URIs on the verified Android
// staging path; direct absolute app-private paths do not need to be copied.
bool thumbnailUsesNativeStaging(String source) =>
    source.startsWith('content://') || source.startsWith('file://');

// Phone and SAF providers may report times as numbers, strings, or dates.
int? thumbnailModifiedMillis(Object? raw) {
  if (raw is num) return raw > 0 ? raw.toInt() : null;
  if (raw is DateTime) return raw.millisecondsSinceEpoch;
  if (raw is String) {
    final millis = int.tryParse(raw.trim());
    if (millis != null) return millis > 0 ? millis : null;
    return DateTime.tryParse(raw)?.millisecondsSinceEpoch;
  }
  return null;
}

/// Lazily renders and persistently caches the first page of a library PDF.
class DocumentThumbnail extends StatefulWidget {
  const DocumentThumbnail({
    super.key,
    required this.documentId,
    required this.storagePath,
    required this.sizeBytes,
    this.contentSha256,
    this.sourceLastModifiedMillis,
  });

  final String documentId;
  final String storagePath;
  final int sizeBytes;
  final String? contentSha256;
  // Phone index modification time, used only when known and positive.
  final int? sourceLastModifiedMillis;

  @override
  State<DocumentThumbnail> createState() => _DocumentThumbnailState();
}

class _DocumentThumbnailState extends State<DocumentThumbnail> {
  late Future<File?> _thumbnail;
  static final Map<String, Future<File?>> _inFlightByDocument =
      <String, Future<File?>>{};
  static const int _thumbnailCacheBudgetBytes = 512 * 1024 * 1024;
  static int _maintenanceRequests = 0;
  static int _activeRenders = 0;
  static const int _maxConcurrentRenders = 3;
  static final List<Completer<void>> _renderWaiters = <Completer<void>>[];

  static Future<void> _acquireRenderSlot() async {
    if (_activeRenders < _maxConcurrentRenders) {
      _activeRenders++;
      return;
    }
    final waiter = Completer<void>();
    _renderWaiters.add(waiter);
    await waiter.future;
  }

  static void _releaseRenderSlot() {
    if (_renderWaiters.isNotEmpty) {
      _renderWaiters.removeAt(0).complete();
    } else {
      if (_activeRenders > 0) _activeRenders--;
    }
  }

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
        oldWidget.sizeBytes != widget.sizeBytes ||
        oldWidget.contentSha256 != widget.contentSha256 ||
        oldWidget.sourceLastModifiedMillis != widget.sourceLastModifiedMillis) {
      _thumbnail = _loadThumbnail();
    }
  }

  Future<bool> _isValidPng(File file) async {
    try {
      if (!await file.exists()) return false;
      final length = await file.length();
      if (length < 45) return false;
      final handle = await file.open(mode: FileMode.read);
      try {
        final header = await handle.read(8);
        await handle.setPosition(length - 12);
        final trailer = await handle.read(12);
        const pngSignature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
        const pngEnd = <int>[0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130];
        if (header.length != 8 || trailer.length != 12) return false;
        for (var i = 0; i < pngSignature.length; i++) {
          if (header[i] != pngSignature[i]) return false;
        }
        for (var i = 0; i < pngEnd.length; i++) {
          if (trailer[i] != pngEnd[i]) return false;
        }
        return true;
      } finally {
        await handle.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// Creates the regeneratable preview cache in app-private support storage.
  /// It is intentionally independent of the portable Documents/SAF location.
  Future<Directory> _thumbnailCacheDirectory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      p.join(support.path, 'docsgrid', 'Cache', 'Thumbnails'),
    );
    await directory.create(recursive: true);
    return directory;
  }

  /// Enforces a soft 512 MiB first-page preview cache using least-recently-used
  /// file timestamps. The preview currently being rendered is never evicted.
  // The 15-Nov version used a portable PagePreviews directory (or the old
  // app-support thumbnails directory). Its valid previews must stay available
  // after an app upgrade; thumbnails are disposable, original PDFs are not.
  Future<File?> _reusePreviousPreview(
    File newCache,
    String digest,
  ) async {
    final oldId = widget.documentId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    // Very long Phone URIs never worked as filenames in the earlier layout.
    if (oldId.length > 160) return null;
    final filename = '${oldId}_${widget.sizeBytes}_$digest.png';
    final support = await getApplicationSupportDirectory();
    final previousDirs = <Directory>[
      Directory(p.join(support.path, 'docsgrid', 'thumbnails')),
    ];
    if (Platform.isAndroid) {
      try {
        final locations = await StorageLocationService.instance
            .portableDataLocationsIfAvailable();
        // Legacy previews are read-only; new previews always use app support.
        final root = locations['rootUri'];
        if (root != null && root.startsWith('file://')) {
          final system = p.join(Uri.parse(root).toFilePath(), 'System');
          previousDirs.add(Directory(p.join(system, 'Cache', 'PagePreviews')));
          previousDirs.add(Directory(p.join(system, 'Thumbnails')));
        }
        for (final key in const ['pagePreviewsUri', 'thumbnailsUri']) {
          final uri = locations[key];
          if (uri != null && uri.startsWith('file://')) {
            previousDirs.add(Directory(Uri.parse(uri).toFilePath()));
          }
        }
      } catch (_) {
        // Permission-limited devices can still create previews from PDFs.
      }
    }
    for (final dir in previousDirs) {
      final oldCache = File(p.join(dir.path, filename));
      if (!await _isValidPng(oldCache)) continue;
      try {
        await oldCache.copy(newCache.path);
        if (await _isValidPng(newCache)) return newCache;
      } catch (_) {
        // The legacy image remains usable without copying it.
      }
      return oldCache;
    }
    return null;
  }

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

  Future<File?> _loadThumbnail() {
    final id = '${widget.documentId}|${widget.storagePath}|${widget.sizeBytes}|${widget.contentSha256 ?? ''}|${widget.sourceLastModifiedMillis ?? ''}';
    final pending = _inFlightByDocument[id];
    if (pending != null) return pending;
    late final Future<File?> shared;
    shared = _loadThumbnailInternal().whenComplete(() {
      if (identical(_inFlightByDocument[id], shared)) {
        _inFlightByDocument.remove(id);
      }
    });
    _inFlightByDocument[id] = shared;
    return shared;
  }

  Future<File?> _loadThumbnailInternal() async {
    final id = _thumbnailIdentity(widget.documentId, widget.storagePath);
    final source = widget.storagePath;
    if (source.isEmpty) return null;

    File? staged;
    pdfx.PdfDocument? document;
    pdfx.PdfPage? page;
    var renderSlotAcquired = false;
    try {
      final directory = await _thumbnailCacheDirectory();
      final isProvider = source.startsWith('content://');
      final isFileUri = source.startsWith('file://');
      String? pdfPath;
      final declaredSha = widget.contentSha256?.trim().toLowerCase();
      String? trustedSha = declaredSha != null &&
              RegExp(r'^[0-9a-f]{64}$').hasMatch(declaredSha)
          ? declaredSha
          : null;
      // Match the previously working native staging path for file:// URIs.
      // Direct Dart File access can be denied by scoped-storage permissions.
      // Files with a regular absolute filesystem path remain direct.
      if (source.startsWith('file:') && !isFileUri) {
        pdfPath = Uri.parse(source).toFilePath();
      } else if (!isProvider && !isFileUri) {
        pdfPath = source;
      }

      File? localPdf;
      if (pdfPath != null) {
        localPdf = File(pdfPath);
        if (!await localPdf.exists()) return null;
      }

      // A stable size/mtime revision avoids rehashing local PDFs. Phone's
      // indexed modified time skips full content-provider copies on cache hits.
      var localFingerprint = '';
      if (localPdf != null) {
        final actualSize = await localPdf.length();
        final modified = await localPdf.lastModified();
        localFingerprint = 'file:${actualSize}:${modified.microsecondsSinceEpoch}';
        if (actualSize != widget.sizeBytes) trustedSha = null;
      }
      final modifiedAt = widget.sourceLastModifiedMillis;
      final providerFingerprint = modifiedAt != null &&
              modifiedAt > 0 && widget.sizeBytes > 0
          ? 'provider:${widget.sizeBytes}:$modifiedAt'
          : null;
      final earlyFingerprint = trustedSha != null
          ? 'sha:$trustedSha:$localFingerprint'
          : localFingerprint.isNotEmpty
              ? localFingerprint
              : providerFingerprint;
      File cacheFor(String fingerprint) => File(p.join(
            directory.path,
            thumbnailCacheFileName(
              documentId: widget.documentId,
              storagePath: source,
              sizeBytes: widget.sizeBytes,
              fingerprint: fingerprint,
            ),
          ));
      if (earlyFingerprint != null) {
        final cached = cacheFor(earlyFingerprint);
        if (await _isValidPng(cached)) {
          try { await cached.setLastModified(DateTime.now()); } catch (_) {}
          _scheduleCacheMaintenance(directory, cached.path);
          return cached;
        }
      }

      // Limit both provider I/O and rendering to three concurrent previews.
      // Acquiring only at the render step previously allowed many full PDF
      // copies/hashes to run simultaneously while a Phone folder opened.
      await _acquireRenderSlot();
      renderSlotAcquired = true;

      // Stage SAF/MediaStore AND file:// PDFs through the verified Android
      // reader. This keeps rendering independent of Android scoped-storage
      // filesystem permissions; cache hits still bypass the copy completely.
      if (thumbnailUsesNativeStaging(source)) {
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
        localPdf = staged;
      }
      if (pdfPath == null || localPdf == null || !await localPdf.exists()) {
        return null;
      }

      // Cache misses verify the current bytes. This also catches same-size
      // replacements instead of rendering under a stale database fingerprint.
      final actualDigest = (await sha256.bind(localPdf.openRead()).first).toString();
      // Do not persist a thumbnail under an incorrect supplied SHA.
      final renderFingerprint = earlyFingerprint != null &&
              (trustedSha == null || trustedSha == actualDigest)
          ? earlyFingerprint
          : 'sha:$actualDigest:$localFingerprint';
      final cache = cacheFor(renderFingerprint);
      if (await _isValidPng(cache)) {
        try { await cache.setLastModified(DateTime.now()); } catch (_) {}
        _scheduleCacheMaintenance(directory, cache.path);
        return cache;
      }
      if (await cache.exists()) {
        try { await cache.delete(); } catch (_) {}
      }

      final reused = await _reusePreviousPreview(cache, actualDigest);
      if (reused != null) {
        _scheduleCacheMaintenance(directory, cache.path);
        return reused;
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
        _scheduleCacheMaintenance(directory, saved.path);
        return saved;
      } finally {
        try {
          if (await partial.exists()) await partial.delete();
        } catch (_) {}
      }
    } catch (error, trace) {
      // Include the exception message in debug logs; the old runtimeType-only
      // log obscured the Android storage permission/verification root cause.
      debugPrint('DocsGrid PDF preview failed: $error');
      debugPrintStack(stackTrace: trace);
      return null;
    } finally {
      if (page != null) {
        try { await page.close(); } catch (_) {}
      }
      if (document != null) {
        try { await document.close(); } catch (_) {}
      }
      if (staged != null) {
        try { if (await staged.exists()) await staged.delete(); } catch (_) {}
      }
      if (renderSlotAcquired) _releaseRenderSlot();
    }
  }

  void _scheduleCacheMaintenance(Directory directory, String keepPath) {
    _maintenanceRequests++;
    if (_maintenanceRequests % 32 == 0) {
      // Cache directory sweeps run rarely and off the thumbnail-hit path.
      unawaited(_enforceThumbnailCacheBudget(directory, keepPath: keepPath));
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
              errorBuilder: (_, error, _) {
                debugPrint('DocsGrid cached PDF preview invalid: ${error.runtimeType}');
                return _placeholder(context, failed: true);
              },
            ),
          );
        }
        // Keep a stable red PDF glyph while the first-page preview loads.
        // A spinner here prevents scrollable widget tests from settling and
        // makes large Phone folders visually noisy during thumbnail warm-up.
        return _placeholder(context,
          failed: snapshot.connectionState == ConnectionState.done);
      },
    );
  }

  Widget _placeholder(BuildContext context, {bool failed = false}) =>
      Container(
        width: 48,
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Tooltip(
          message: failed ? 'PDF preview unavailable' : 'PDF preview',
          child: Stack(
            alignment: Alignment.center,
            children: [
              const Icon(Icons.picture_as_pdf_rounded,
                  size: 38, color: Color(0xFFD32F2F)),
              if (failed)
                const Positioned(
                  right: 0, bottom: 0,
                  child: Icon(Icons.error_outline, size: 17,
                      color: Color(0xFFB71C1C)),
                ),
            ],
          ),
        ),
      );
}
