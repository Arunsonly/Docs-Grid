import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String source;

  setUpAll(() {
    source = File('lib/features/folders/presentation/folders_screen.dart')
        .readAsStringSync();
  });

  test('root Grid empty state has exact approved heading and description', () {
    expect(source, contains("'All Your Docs. One Smart Place.'"));
    expect(source, contains("Organize with folders, categories & tags."));
    expect(source, contains("Find faster, avoid duplicates & share easily."));
    expect(source, isNot(contains("'No folders or PDFs yet'")));
  });

  test('empty message applies only to empty unsearched root', () {
    expect(source, contains('if (displayedFolders.isEmpty && documents.isEmpty &&'));
    expect(source, contains('(_isReorderingFolders || !folder.externallyEmptied)'));
    expect(source, contains('(!_pagedDocumentsMode || _pagedTotalCount == 0) &&'));
    expect(source, contains('query.isEmpty) {'));
    expect(source, contains('_currentFolderId == null'));
    expect(source, contains("'This folder is empty'"));
    expect(source, contains("'Create a folder or import a PDF to get started.'"));
  });

  test('folder creation and normal folder / document lists remain untouched', () {
    expect(source, contains('onPressed: _createFolder'));
    expect(source, contains("label: const Text('Create folder')"));
    expect(source, contains('return NotificationListener<ScrollNotification>('));
    expect(source, contains('RefreshIndicator('));
  });
}
