import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('shipped app has no OCR setting or search-mode toggle', () {
    final main = File('lib/main.dart').readAsStringSync();
    final screen = File('lib/features/documents/presentation/documents_screen.dart')
        .readAsStringSync();
    final engine = File('lib/features/tools/document_tools_service.dart')
        .readAsStringSync();

    expect(main, isNot(contains("enable-ocr-search-setting")));
    expect(main, isNot(contains('OcrSearchPreferences')));
    expect(main, isNot(contains('ocrSearchAvailable:')));
    expect(main, contains('phoneOnly: true,'));
    expect(main, contains('_ => FoldersScreen('));
    expect(screen, contains("hintText: _searchInsideText ? 'Search text inside PDFs' : 'Search PDF names'"));
    // Internal compatibility remains, but production never enables the mode.
    expect(screen, contains('if (widget.ocrSearchAvailable)'));
    expect(engine, contains('indexPendingPdfsForSearch('));
    expect(engine, contains("!uri.startsWith('missing://')"));
    // Exact duplicates / backup metadata stay compatible with old indexed rows.
    expect(engine, contains('findDuplicateGroups()'));
    expect(engine, contains("'document_text_index'"));
  });

  test('OCR changes do not resurrect automatic destructive migration', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, isNot(contains('migrateLegacyStorageToCanonicalIfNeeded()')));
    final repository = File('lib/features/documents/data/document_repository.dart')
        .readAsStringSync();
    expect(repository, contains('Future<int> migrateExistingLibraryToSelectedStorage('));
  });
}
