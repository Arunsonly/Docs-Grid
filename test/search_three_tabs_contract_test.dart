import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Phone and Home retain distinct keys; OCR mode is never enabled by app shell',
      () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains("ValueKey('phone-tab')"));
    expect(main, contains("ValueKey('home-tab')"));
    expect(main, contains('phoneOnly: true,'));
    expect(main, contains('IndexedStack('));
    expect(main, contains('? FoldersScreen('));
    expect(main, contains('onOpenSettings: _openSettings,'));
    expect(main, isNot(contains('ocrSearchAvailable:')));
    expect(main, isNot(contains('enable-ocr-search-setting')));
  });

  test('Home live filename query displays matches before its dashboard sections',
      () {
    final home = File('lib/features/documents/presentation/documents_screen.dart')
        .readAsStringSync();
    expect(home, contains('query: _search.text,'));
    expect(home, contains('_search.addListener(_onSearchChanged)'));
    expect(home, contains('_phoneStorageSearchMatches(_search.text)'));
    expect(home, contains('Grid Storage'));
    expect(home, contains('Phone Storage'));
    expect(home, contains('_search.text.trim().isEmpty)'));
    expect(home, contains('if (!widget.favoritesOnly && _search.text.trim().isNotEmpty)'));
    expect(home, isNot(contains('OcrSearchModeControl(')));
  });

  test('Grid uses filename queries and retains folder matching', () {
    final grid = File('lib/features/folders/presentation/folders_screen.dart').readAsStringSync();
    expect(grid, contains('_documents.list(query: query)'));
    expect(grid, contains('folder.name.toLowerCase().contains(query)'));
    expect(grid, contains('document.name.toLowerCase().contains(query)'));
    expect(grid, isNot(contains('OcrSearchModeControl(')));
  });

  test('Phone and Home retain filename search without OCR controls', () {
    final phone = File('lib/features/documents/presentation/phone_storage_browser_screen.dart').readAsStringSync();
    final home = File('lib/features/documents/presentation/documents_screen.dart').readAsStringSync();
    expect(phone, contains('Search phone folders or PDF names'));
    expect(phone, contains('name.contains(query)'));
    expect(phone, isNot(contains('PhoneOcrSearchIndex')));
    expect(home, contains('_phoneStorageSearchMatches(_search.text)'));
  });
}
