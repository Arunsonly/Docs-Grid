import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new and edit collections use one simplified editor with Grid-only preview', () {
    final source = File('lib/features/documents/presentation/smart_collections_screen.dart').readAsStringSync();
    expect(source, isNot(contains('Starred PDFs only')));
    expect(source, isNot(contains('Recently opened only')));
    expect(source, contains("Text('Tags'"));
    expect(source, contains("Text('New tag'"));
    expect(source, contains('widget.repository.createTag(name)'));
    expect(source, contains('widget.count(draft)'));
    expect(source, contains("Text('No filter selected'"));
    expect(source, contains("Text('Save all PDFs'"));
    expect(source, contains("FROM documents WHERE"));
    expect(source, contains("FROM documents d WHERE"));
    expect(source, contains("deleted_at IS NULL"));
    expect(source, contains("'favorites_only': 0"));
    expect(source, contains("'recent_only': 0"));
  });
}
