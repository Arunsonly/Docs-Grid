import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../core/database/app_database.dart';
import '../../../core/storage/storage_location_service.dart';

class PdfInsightsService {
  PdfInsightsService({AppDatabase? database})
      : _database = database ?? AppDatabase.instance;

  final AppDatabase _database;

  /// Extracts searchable text on-device. Scanned/image-only PDFs return an
  /// empty string; OCR is deliberately not implied or sent to a cloud service.
  Future<String> extractText(String storageLocation) async {
    var temporaryPath = '';
    String path;
    if (storageLocation.startsWith('content://') ||
        storageLocation.startsWith('file://')) {
      final temp = await getTemporaryDirectory();
      final file = File(p.join(
        temp.path,
        'docsgrid-index-${DateTime.now().microsecondsSinceEpoch}.pdf',
      ));
      temporaryPath = file.path;
      await StorageLocationService.instance.copyPdfToPath(
        sourceUri: storageLocation,
        destinationPath: temporaryPath,
      );
      path = temporaryPath;
    } else {
      path = storageLocation;
    }

    try {
      final file = File(path);
      if (!await file.exists()) throw StateError('PDF file is not available for text indexing.');
      final document = await PdfDocument.openFile(path);
      try {
        final text = StringBuffer();
        for (final page in document.pages) {
          final pageText = await page.loadText();
          final value = pageText?.fullText ?? '';
          if (value.isNotEmpty) {
            text.writeln(value);
            // Keep the local index bounded on very large PDFs.
            if (text.length >= 1000000) break;
          }
        }
        return text.toString().trim();
      } finally {
        await document.dispose();
      }
    } finally {
      if (temporaryPath.isNotEmpty) {
        try {
          final temp = File(temporaryPath);
          if (await temp.exists()) await temp.delete();
        } catch (_) {
          // A leftover cache file is harmless; indexing never deletes the PDF.
        }
      }
    }
  }

  Future<bool> indexDocument(String documentId, String storageLocation) async {
    final db = await _database.database;
    try {
      final text = await extractText(storageLocation);
      await db.update(
        'documents',
        {
          'extracted_text': text,
          'extracted_text_status': text.isEmpty ? 'no_text' : 'indexed',
          'text_indexed_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [documentId],
      );
      return text.isNotEmpty;
    } catch (_) {
      await db.update(
        'documents',
        {'extracted_text_status': 'failed'},
        where: 'id = ? AND deleted_at IS NULL',
        whereArgs: [documentId],
      );
      return false;
    }
  }

  String? suggestName({required String currentName, required String text}) {
    final lines = text
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((line) => line.length >= 4)
        .toList();
    if (lines.isEmpty) return null;

    final candidate = lines.first
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (candidate.length < 4) return null;
    final cleaned = candidate.length > 64 ? candidate.substring(0, 64).trim() : candidate;
    if (cleaned.toLowerCase() == currentName.toLowerCase()) return null;
    return cleaned;
  }

  String? suggestCategory({required String fileName, required String text}) {
    final source = '${fileName.toLowerCase()} ${text.toLowerCase()}';
    const rules = <String, List<String>>{
      'Identity': ['aadhaar', 'aadhar', 'passport', 'pan card', 'voter id', 'driving licence'],
      'Insurance': ['insurance', 'policy number', 'premium', 'nominee', 'claim form', 'insurer'],
      'Finance': ['bank statement', 'account number', 'income tax', 'itr', 'gst', 'loan account', 'invoice'],
      'Medical': ['hospital', 'prescription', 'diagnosis', 'medical report', 'blood test', 'patient'],
      'Property': ['sale deed', 'property', 'lease agreement', 'rent agreement', 'land registry'],
      'Vehicle': ['registration certificate', 'vehicle number', 'chassis number', 'motor insurance', 'rc book'],
      'Education': ['marksheet', 'transcript', 'certificate', 'university', 'school'],
    };

    var bestCategory = '';
    var bestScore = 0;
    for (final entry in rules.entries) {
      final score = entry.value.where(source.contains).length;
      if (score > bestScore) {
        bestScore = score;
        bestCategory = entry.key;
      }
    }
    return bestScore == 0 ? null : bestCategory;
  }
}
