import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Grid PDFs use Android Open with and an app-readable URI', () {
    final native = File('platform/android/MainActivity.kt').readAsStringSync();
    final storage = File('lib/core/storage/storage_location_service.dart')
        .readAsStringSync();
    final workflow = File('.github/workflows/flutter-ci.yml').readAsStringSync();
    final folders = File('lib/features/folders/presentation/folders_screen.dart')
        .readAsStringSync();
    final documents = File('lib/features/documents/presentation/documents_screen.dart')
        .readAsStringSync();
    final collections = File(
      'lib/features/documents/presentation/smart_collections_screen.dart',
    ).readAsStringSync();
    final tools = File('lib/features/tools/document_tools_screen.dart')
        .readAsStringSync();

    expect(native, contains('FileProvider.getUriForFile('));
    expect(native, contains('ClipData.newUri(contentResolver, "PDF", viewUri)'));
    expect(native, contains('Intent.createChooser(intent, "Open PDF")'));
    expect(native, contains('Intent.FLAG_GRANT_READ_URI_PERMISSION'));
    expect(native, contains('staged.parentFile != sharedCache'));
    expect(workflow, contains('docsgrid_grid_pdf_paths.xml'));
    expect(workflow, contains('<cache-path name="grid_pdf" path="docsgrid_grid_pdf/" />'));

    expect(storage, contains("await copyPdfToPath("));
    expect(storage, contains("'gridPdf': true"));
    expect(storage, contains("if (gridPdf && Platform.isAndroid)"));
    // The retired OCR tools menu no longer exposes a PDF-opening action.
    // Retain the same chooser contract for every remaining Grid PDF entry point.
    for (final screen in [folders, documents, collections]) {
      expect(screen, contains('gridPdf: true'));
      expect(screen, isNot(contains('DocumentPdfViewerScreen(')));
    }
    // Backup and Recovery must not resurrect the retired OCR opening routes.
    expect(tools, isNot(contains('_openSearchResult(')));
    expect(tools, isNot(contains('DocumentPdfViewerScreen(')));
    expect(tools, isNot(contains('openPdf(')));
    expect(tools, contains("Text('Emergency Recovery')"));
    expect(folders, isNot(contains('_openGridPdf(')));
    // Phone Storage retains its original, non-Grid opening path.
    expect(documents, contains('Future<void> _openExternalStoragePdf('));
    expect(documents, contains('StorageLocationService.instance.openPdf(uri);'));
  });

  test('Android PDF preview copy can verify its private staging file', () {
    final source = File('platform/android/MainActivity.kt').readAsStringSync();
    final start = source.indexOf('"copyPdfToPath" -> {');
    final end = source.indexOf('"sha256Pdf" -> {', start);
    expect(start, greaterThan(-1));
    expect(end, greaterThan(start));
    final copyCode = source.substring(start, end);
    expect(copyCode, contains('openPdfSource(source, allowAppPrivateFile = true)'));
    expect(copyCode, contains('digest(source, allowAppPrivateFile = true)'));
    expect(copyCode, contains(
        'digest(Uri.fromFile(temporary), allowAppPrivateFile = true)'));
  });
}
