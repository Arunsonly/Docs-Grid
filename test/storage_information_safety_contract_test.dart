import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
void main() {
  test('storage screen clears only explicit private regeneratable preview locations', () {
    final source=File('lib/core/storage/storage_information_screen.dart').readAsStringSync();
    expect(source,contains("'docsgrid_folder_previews_v1'"));
    expect(source,contains("'Cache','Thumbnails'"));
    expect(source,contains('followLinks:false'));
    expect(source,isNot(contains('delete(recursive:')));
    expect(source,contains('getApplicationSupportDirectory()'));
    expect(source,contains("entry['size']"));
    final settings=File('lib/main.dart').readAsStringSync();
    expect(settings,contains("_sectionTitle('DOCUMENT MANAGEMENT')"));
    expect(settings,contains("_sectionTitle('DATA & STORAGE')"));
    expect(settings,contains("Text('Storage Information'"));
  });
}
