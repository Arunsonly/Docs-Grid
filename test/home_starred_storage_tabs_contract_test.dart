import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;
  setUpAll(() {
    source = File('lib/features/documents/presentation/documents_screen.dart')
        .readAsStringSync();
  });

  test('Starred has same Phone/Grid segmented switch as Recent', () {
    expect(source, contains("Text(_showStarredRecent ? 'Starred' : 'Recent'"));
    expect(source, contains("ButtonSegment(value: 'phone', label: Text('Phone'))"));
    expect(source, contains("ButtonSegment(value: 'grid', label: Text('Grid'))"));
    expect(source,
        contains('selected: {_showStarredRecent ? _starredFilter : _recentFilter}'));
    expect(source,
        isNot(contains('if (!_showStarredRecent)\n                        SegmentedButton')));
  });

  test('Starred and Recent keep independent selections', () {
    expect(source, contains("String _starredFilter = 'phone';"));
    expect(source, contains("String _recentFilter = 'grid';"));
    expect(source, contains('if (_showStarredRecent) {\n'
        '                            _starredFilter = selection.first;\n'
        '                          } else {\n'
        '                            _recentFilter = selection.first;'));
  });

  test('Starred Phone and Grid are filtered to the correct repository results', () {
    expect(source, contains("? _starredFilter == 'phone'"));
    expect(source, contains('itemCount: _phoneStarred.length,'));
    expect(source, contains('_phoneStarredTile(_phoneStarred[index])'));
    expect(source, contains('itemCount: _starredRecent.length,'));
    expect(source, contains('_recentDocumentTile(_starredRecent[index])'));
    expect(source, contains("No starred Phone PDFs"));
    expect(source, contains("No starred Grid PDFs"));
    expect(source,
        isNot(contains('itemCount: _phoneStarred.length + _starredRecent.length')));
  });

  test('Existing Recent lists and safe favorite handlers are unchanged', () {
    expect(source, contains(" : _recentFilter == 'phone'"));
    expect(source, contains('itemCount: _phoneRecent.length,'));
    expect(source, contains('itemCount: _gridRecent.length,'));
    expect(source, contains('_loadAllStarred()'));
    expect(source, contains('PhoneStarRepository.toggle('));
    expect(source, contains('_repository.setFavorite(document, !document.isFavorite)'));
    expect(source, contains('_handlePhoneRecentAction(item, action)'));
  });
}
