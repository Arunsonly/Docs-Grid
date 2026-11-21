import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Settings merely reveals OCR; main Search remains filename-first', () {
    final main = File('lib/main.dart').readAsStringSync();
    final screen = File('lib/features/documents/presentation/documents_screen.dart')
        .readAsStringSync();
    final engine = File('lib/features/tools/document_tools_service.dart')
        .readAsStringSync();

    expect(main, contains("key: const ValueKey('enable-ocr-search-setting')"));
    expect(main, contains('ocrSearchAvailable: widget.ocrSearchAvailable'));
    expect(screen, contains('bool _searchInsideText = false;'));
    expect(screen, contains('if (widget.ocrSearchAvailable)'));
    expect(screen, contains('OcrSearchModeControl('));
    expect(screen, contains('if (!widget.ocrSearchAvailable || _searchInsideText == enabled) return;'));
    expect(screen, contains('if (_searchInsideText && widget.ocrSearchAvailable)'));
    expect(screen, contains('_search.text.trim().isEmpty || _ocrIndexing || _ocrIndexStarted'));
    expect(engine, contains('indexPendingPdfsForSearch('));
    expect(engine, contains("!uri.startsWith('missing://')"));
    expect(engine, contains('if (shouldCancel?.call() ?? false) throw const OcrIndexCancelled();'));
  });

  test('OCR changes do not resurrect automatic destructive migration', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, isNot(contains('migrateLegacyStorageToCanonicalIfNeeded()')));
    final repository = File('lib/features/documents/data/document_repository.dart')
        .readAsStringSync();
    expect(repository, contains('Future<int> migrateExistingLibraryToSelectedStorage('));
  });
}
