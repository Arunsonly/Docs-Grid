import 'dart:io';

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

  Future<File?> _loadThumbnail() async {
    final id = widget.documentId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'docsgrid', 'thumbnails'));
    await directory.create(recursive: true);
    final cache = File(p.join(directory.path, '${id}_${widget.sizeBytes}.png'));
    if (await cache.exists() && await cache.length() > 0) return cache;

    final source = widget.storagePath;
    if (source.isEmpty) return null;
    String pdfPath = source;
    File? staged;
    if (source.startsWith('content://') || source.startsWith('file://')) {
      final temp = await getTemporaryDirectory();
      staged = File(p.join(temp.path, 'thumb_${id}_${DateTime.now().microsecondsSinceEpoch}.pdf'));
      try {
        await StorageLocationService.instance.copyPdfToPath(
          sourceUri: source,
          destinationPath: staged.path,
        );
        pdfPath = staged.path;
      } catch (_) {
        try {
          if (await staged.exists()) await staged.delete();
        } catch (_) {}
        return null;
      }
    } else if (source.startsWith('file:')) {
      pdfPath = Uri.parse(source).toFilePath();
    }

    pdfx.PdfDocument? document;
    pdfx.PdfPage? page;
    try {
      if (!await File(pdfPath).exists()) return null;
      document = await pdfx.PdfDocument.openFile(pdfPath);
      if (document.pagesCount < 1) return null;
      page = await document.getPage(1);
      final width = 240.0;
      final height = (width * page.height / page.width).clamp(160.0, 360.0);
      final rendered = await page.render(
        width: width,
        height: height,
        format: pdfx.PdfPageImageFormat.png,
      );
      if (rendered == null || rendered.bytes.isEmpty) return null;
      final partial = File('${cache.path}.tmp');
      await partial.writeAsBytes(rendered.bytes, flush: true);
      if (await cache.exists()) await cache.delete();
      return await partial.rename(cache.path);
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
        return _placeholder(context, loading: snapshot.connectionState != ConnectionState.done);
      },
    );
  }

  Widget _placeholder(BuildContext context, {bool loading = false}) => Container(
    width: 48,
    height: 64,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: loading
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(Icons.picture_as_pdf_outlined, color: Theme.of(context).colorScheme.primary),
  );
}
