import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('retired preferences and viewer files are absent and active PDF paths remain', () {
    expect(File('lib/core/settings/ocr_search_preferences.dart').existsSync(), isFalse);
    expect(File('lib/features/documents/presentation/document_pdf_viewer_screen.dart').existsSync(), isFalse);
    final main = File('lib/main.dart').readAsStringSync();
    final storage = File('lib/core/storage/storage_location_service.dart').readAsStringSync();
    final thumbnails = File('lib/features/documents/presentation/document_thumbnail.dart').readAsStringSync();
    final tools = File('lib/features/tools/document_tools_screen.dart').readAsStringSync();
    final ci = File('.github/workflows/flutter-ci.yml').readAsStringSync();
    expect(main, isNot(contains("Text('Default view'")));
    expect(main, contains('importScannedPdf('));
    expect(main, contains("sourceType: 'share'"));
    expect(storage, contains('Future<void> openPdf('));
    expect(thumbnails, contains('pdfx.PdfDocument.openFile'));
    expect(tools, isNot(contains("widget.quickAction == 'camera'")));
    expect(tools, isNot(contains("widget.quickAction == 'gallery'")));
    expect(tools, contains("Text('Emergency Recovery')"));
    expect(ci, isNot(contains('android.permission.CAMERA')));
    expect(ci, isNot(contains('NSCameraUsageDescription')));
    expect(ci, isNot(contains('NSPhotoLibraryUsageDescription')));
    expect(ci, contains('android.permission.POST_NOTIFICATIONS'));
    expect(ci, contains('CFBundleDocumentTypes'));
  });

  test('Grid single and bulk sharing retain the active service import', () {
    final grid = File('lib/features/folders/presentation/folders_screen.dart').readAsStringSync();
    final service = File('lib/features/tools/document_tools_service.dart').readAsStringSync();
    expect(grid, contains("import '../../tools/document_tools_service.dart';"));
    expect(grid, contains('DocumentToolsService().shareManyStoredPdfs('));
    expect(grid, contains('DocumentToolsService().shareStoredPdf('));
    expect(service, contains('Future<void> shareManyStoredPdfs('));
    expect(service, contains('Future<void> shareStoredPdf('));
    expect(grid, isNot(contains('OcrSearchModeControl(')));
  });
}
