import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Phone and Home retain distinct keys; OCR mode is never enabled by app shell',
      () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains("ValueKey('phone-tab')"));
    expect(main, contains("ValueKey('home-tab')"));
    expect(main, contains('phoneOnly: true,'));
    expect(main, contains('_ => FoldersScreen('));
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
    expect(home.indexOf('OcrSearchModeControl('),
        lessThan(home.indexOf('final matches = _searchInsideText')));
  });

  test('Grid OCR mode does not run the filename filter on text matches', () {
    final grid = File('lib/features/folders/presentation/folders_screen.dart')
        .readAsStringSync();
    expect(grid, contains('_searchGridOcr(query)'));
    expect(grid, contains('_ocrTools.searchText(query)'));
    expect(grid, contains('query.isEmpty || _ocrSelected ||'));
    expect(grid, contains('if (widget.ocrSearchAvailable)'));
  });

  test('Phone and Home OCR use transient Phone text and no popup chooser', () {
    final control = File(
      'lib/features/documents/presentation/ocr_search_mode_control.dart')
        .readAsStringSync();
    expect(control, contains('onTap: () => onChanged(!searchInsidePdf)'));
    expect(control, isNot(contains('PopupMenuButton')));
    final phone = File(
      'lib/features/documents/presentation/phone_storage_browser_screen.dart')
        .readAsStringSync();
    expect(phone, contains('PhoneOcrSearchIndex('));
    expect(phone, contains('_ocrIndex.matches(_pdfs, query)'));
    final home = File(
      'lib/features/documents/presentation/documents_screen.dart')
        .readAsStringSync();
    expect(home, contains('_phoneOcrIndex.matches(_phoneEntries, _search.text)'));
  });
}
