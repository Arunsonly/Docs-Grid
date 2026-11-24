import 'dart:io';
import 'package:flutter/material.dart';
import '../data/document_repository.dart';

class PdfDetailsDialog {
  static String fullName(String name) => name.toLowerCase().endsWith('.pdf') ? name : '$name.pdf';

  static DateTime? modified(Object? value) {
    if (value is DateTime) return value;
    if (value is num && value > 0) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  static String sizeLabel(int? bytes) {
    if (bytes == null || bytes < 0) return 'Unavailable';
    if (bytes >= 1073741824) return '${(bytes / 1073741824).toStringAsFixed(2)} GB ($bytes bytes)';
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(2)} MB ($bytes bytes)';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB ($bytes bytes)';
    return '$bytes bytes';
  }

  static String dateLabel(DateTime? value) {
    if (value == null) return 'Unavailable';
    final date = value.toLocal();
    String two(int n) => n.toString().padLeft(2,'0');
    return '${two(date.day)}/${two(date.month)}/${date.year} · ${two(date.hour)}:${two(date.minute)}';
  }

  static String location(String uri, String? folder, String name) {
    if (uri.startsWith('file://')) {
      try { return Uri.parse(uri).toFilePath(); } catch (_) {}
    }
    if (uri.startsWith('/')) return uri;
    final path = folder?.trim() ?? '';
    if (path.isNotEmpty) return path.endsWith('/') ? path + fullName(name) : '$path/${fullName(name)}';
    return uri.isEmpty ? 'Unavailable' : uri;
  }

  static Future<void> showGrid(BuildContext context, DocumentRecord doc) =>
    show(context, name: doc.name, uri: doc.storagePath, bytes: doc.sizeBytes,
      updated: doc.updatedAt, grid: true);

  static Future<void> showPhone(BuildContext context, Map<String,Object?> row) =>
    show(context, name: row['name'] as String? ?? 'PDF', uri: row['uri'] as String? ?? '',
      bytes: ((row['sizeBytes'] ?? row['size']) as num?)?.toInt(),
      updated: modified(row['lastModified']),
      folder: (row['folderPath'] ?? row['path'])?.toString(), grid: false);

  static Future<void> show(BuildContext context, {required String name, required String uri,
    required int? bytes, required DateTime? updated, String? folder, required bool grid}) async {
    // Read metadata only. Do not open, copy or scan the PDF.
    if (uri.startsWith('file://') || uri.startsWith('/')) {
      try {
        final path = uri.startsWith('file://') ? Uri.parse(uri).toFilePath() : uri;
        final stat = await File(path).stat();
        if (stat.type == FileSystemEntityType.file) { bytes = stat.size; updated = stat.modified; }
      } catch (_) { /* retain stored metadata if physical access fails */ }
    }
    if (!context.mounted) return;
    await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Details'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(grid ? 'Grid Storage' : 'Phone Storage', style: Theme.of(ctx).textTheme.labelLarge),
        for (final field in [
          ('Full PDF name', fullName(name)),
          ('File size', sizeLabel(bytes)),
          ('Last updated', dateLabel(updated)),
          ('Path', location(uri, folder, name)),
          if (uri.startsWith('content://') && folder?.isNotEmpty == true) ('Storage URI', uri),
        ]) ...[
          const SizedBox(height:12),
          Text(field.$1, style: Theme.of(ctx).textTheme.labelLarge),
          SelectableText(field.$2),
        ],
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
    ));
  }
}
