import 'dart:async';
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
    this.contentSha256,
  });

  final String documentId;
  final String storagePath;
  final int sizeBytes;
  final String? contentSha256;

  @override
  State<DocumentThumbnail> createState() => _DocumentThumbnailState();
}

class _DocumentThumbnailState extends State<DocumentThumbnail> {
  late Future<File?> _thumbnail;
  static final Map<String, Future<File?>> _inFlightByDocument =
      <String, Future<File?>>{};
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
        oldWidget.contentSha256 != widget.contentSha256) {
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

  Future<File?> _loadThumbnail() {
    final id = '${widget.documentId}|${widget.storagePath}|${widget.sizeBytes}|${widget.contentSha256 ?? ''}';
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
    final id = widget.documentId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final source = widget.storagePath;
    if (source.isEmpty) return null;

    File? staged;
    pdfx.PdfDocument? document;
    pdfx.PdfPage? page;
    var renderSlotAcquired = false;
    try {
      final directory = await _thumbnailCacheDirectory();
      final isProvider = source.startsWith('content://');
      String? pdfPath;
      String? digest = widget.contentSha256?.trim();
      if (source.startsWith('file://') || source.startsWith('file:')) {
        pdfPath = Uri.parse(source).toFilePath();
      } else if (!isProvider) {
        pdfPath = source;
      }

      File? localPdf;
      if (pdfPath != null) {
        localPdf = File(pdfPath);
        if (!await localPdf.exists()) return null;
      }

      // A persisted SHA lets us locate the cache without first copying a
      // content:// PDF to temporary storage. For local files, use mtime/size as
      // a cheap invalidation hint; re-hash only on a cache miss.
      var localFingerprint = '';
      if (localPdf != null) {
        final actualSize = await localPdf.length();
        final modified = await localPdf.lastModified();
        localFingerprint = '_${actualSize}_${modified.millisecondsSinceEpoch}';
        if (actualSize != widget.sizeBytes) digest = null;
      }
      if (digest != null && digest.isNotEmpty) {
        final cache = File(p.join(
          directory.path,
          '${id}_${widget.sizeBytes}_${digest}${localFingerprint}.png',
        ));
        if (await _isValidPng(cache)) {
          try { await cache.setLastModified(DateTime.now()); } catch (_) {}
          _scheduleCacheMaintenance(directory, cache.path);
          return cache;
        }
      }

      // Stage provider-backed PDFs only after the known-fingerprint cache lookup
      // has missed. This keeps cache hits independent of provider latency.
      if (isProvider) {
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
      digest = actualDigest;
      final actualSize = await localPdf.length();
      final cache = File(p.join(
        directory.path,
        '${id}_${actualSize}_${digest}${localFingerprint}.png',
      ));
      if (await _isValidPng(cache)) {
        try { await cache.setLastModified(DateTime.now()); } catch (_) {}
        _scheduleCacheMaintenance(directory, cache.path);
        return cache;
      }
      if (await cache.exists()) {
        try { await cache.delete(); } catch (_) {}
      }

      await _acquireRenderSlot();
      renderSlotAcquired = true;
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
    } catch (_) {
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
