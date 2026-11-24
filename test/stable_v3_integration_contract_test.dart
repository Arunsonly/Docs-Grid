import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stable v3 candidate retains the advanced UI and integrated Recycle Bin', () {
    final main=File('lib/main.dart').readAsStringSync();
    final docs=File('lib/features/documents/presentation/documents_screen.dart').readAsStringSync();
    final details=File('lib/features/documents/presentation/pdf_details_dialog.dart').readAsStringSync();
    final collections=File('lib/features/documents/presentation/smart_collections_screen.dart').readAsStringSync();
    final inbox=File('lib/features/reminders/presentation/reminder_inbox_sheet.dart').readAsStringSync();
    expect(main, contains("Text('Storage Information'"));
    expect(main, contains("Text('Already in DocsGrid'"));
    expect(docs, contains("deleteFolder: _folderRepository.permanentlyDeleteTrashFolderTree"));
    expect(docs, contains("Text('Details')"));
    expect(docs, contains('return terms.every(name.contains);'));
    expect(details, isNot(contains("('Storage URI', uri)")));
    expect(collections, contains('Choose PDFs'));
    expect(inbox, contains("Text('Mark completed')"));
  });
}
