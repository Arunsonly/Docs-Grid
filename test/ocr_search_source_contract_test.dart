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
    expect(main, contains('IndexedStack('));
    expect(main, contains('? FoldersScreen('));
    expect(screen, contains("hintText: 'Search PDF names'"));
    expect(screen, isNot(contains('OcrSearchModeControl')));
    expect(engine, isNot(contains('indexPendingPdfsForSearch(')));
    expect(engine, isNot(contains('TextRecognizer')));
    expect(engine, contains('findExactDuplicates()'));
    expect(engine, contains("'document_text_index'"));
    expect(File('lib/features/documents/data/phone_ocr_search_index.dart').existsSync(), isFalse);
    expect(File('pubspec.yaml').readAsStringSync(), isNot(contains('google_mlkit')));

  });

  test('OCR changes do not resurrect automatic destructive migration', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, isNot(contains('migrateLegacyStorageToCanonicalIfNeeded()')));
    final repository = File('lib/features/documents/data/document_repository.dart')
        .readAsStringSync();
    expect(repository, contains('Future<int> migrateExistingLibraryToSelectedStorage('));
    expect(repository, isNot(contains('migrateLegacyStorageToCanonicalIfNeeded(')));
  });
}
