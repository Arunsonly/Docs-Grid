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

  Future<Directory> _thumbnailCacheDirectory() async {
    // Keep the portable thumbnail cache in the agreed DocsGrid-owned tree
    // whenever Android exposes it. This lets the cache survive app updates and
    // keeps Recent/Grid previews beside the portable database and recovery data.
    if (Platform.isAndroid) {
      try {
        final locations = await StorageLocationService.instance
            .portableDataLocationsIfAvailable();
        final thumbnailsUri = locations['thumbnailsUri'];
        if (thumbnailsUri != null && thumbnailsUri.startsWith('file://')) {
          final directory = Directory(Uri.parse(thumbnailsUri).toFilePath());
          await directory.create(recursive: true);
          return directory;
        }
      } catch (_) {
        // Without optional shared-storage access, use the private cache below.
      }
    }
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'docsgrid', 'thumbnails'));
    await directory.create(recursive: true);
    return directory;
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
      if (await _isValidPng(cache)) {
        await _removeOldCacheFiles(directory, prefix, keepPath: cache.path);
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
        return _placeholder(
          context,
          loading: snapshot.connectionState != ConnectionState.done,
        );
      },
    );
  }

  Widget _placeholder(BuildContext context, {bool loading = false}) =>
      Container(
        width: 48,
        height: 64,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(
                Icons.picture_as_pdf_rounded,
                size: 38,
                color: Color(0xFFD32F2F),
              ),
      );
}
