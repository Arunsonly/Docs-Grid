import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String home;
  setUpAll(() {
    home = File('lib/features/documents/presentation/documents_screen.dart')
        .readAsStringSync();
  });

  test('Home search has independent Phone and Grid tabs, never the old dropdown', () {
    expect(home, contains("ValueKey(phone ? 'home-search-phone-tab' : 'home-search-grid-tab')"));
    expect(home, contains("title: 'Phone Storage'"));
    expect(home, contains("title: 'Grid Storage'"));
    expect(home, contains('if (_homeSearchPhoneSelected) ...['));
    expect(home, contains("(_search.text.trim().isNotEmpty && !_homeSearchPhoneSelected)"));
    expect(home, isNot(contains('height: (matches.length.clamp(1, 4) * 64)')));
  });

  test('Phone results stay visible during background scans', () {
    expect(home, contains('if (matches.isEmpty && _phoneScanLoading)'));
    expect(home, contains('if (matches.isNotEmpty)'));
    expect(home, contains('itemBuilder: (_, index) => _homePhoneSearchTile(matches[index])'));
    expect(home, contains('Show more Phone PDFs'));
    expect(home, contains('_homePhoneSearchPageSize = 40'));
    expect(home, contains('_homePhoneSearchVisibleCount += _homePhoneSearchPageSize'));
    expect(home, contains('_search.text.trim().isNotEmpty && _homeSearchPhoneSelected) return;'));
  });

  test('Home dashboard and existing search/OCR entry points are preserved', () {
    expect(home, contains('_search.addListener(_onSearchChanged)'));
    expect(home, contains('OcrSearchModeControl('));
    expect(home, contains('_setOcrSearchMode'));
    expect(home, contains('_phoneOcrIndex.matches(_phoneEntries, _search.text)'));
    expect(home, contains('_search.text.trim().isEmpty)'));
    expect(home, contains('if (!widget.favoritesOnly && !widget.recentOnly &&'));
    expect(home, contains('widget.phoneOnly'));
  });

  test('Phone Home search uses matching Grid cards and existing safe actions', () {
    expect(home, contains("key: ValueKey('home-phone-pdf-"));
    expect(home, contains("documentId: 'phone_"));
    expect(home, contains('sourceLastModifiedMillis: thumbnailModifiedMillis'));
    expect(home, contains('await _sharePhonePdf(uri, name)'));
    expect(home, contains('await _recordExternalFavorite(uri, name)'));
    expect(home, contains('await _renamePhonePdf(uri, name)'));
    expect(home, contains('await _movePhonePdfWithinPhone(uri, name)'));
    expect(home, contains('await _movePhonePdfToGrid(uri, name)'));
    expect(home, contains('await _trashPhonePdf(uri, name)'));
    expect(home, contains('onTap: () => _openExternalStoragePdf(uri, name)'));
    expect(home, contains('OcrSearchModeControl('));
    expect(home, contains('_phoneOcrIndex.matches(_phoneEntries, _search.text)'));
    expect(home, contains('_phoneStorageSearchMatches(_search.text)'));
  });
}
