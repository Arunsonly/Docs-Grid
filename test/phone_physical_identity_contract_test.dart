import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android physical identity guard is wired before destructive Phone Delete',
      () {
    final native = File('platform/android/MainActivity.kt').readAsStringSync();
    final dart = File('lib/features/documents/data/document_repository.dart')
        .readAsStringSync();
    final storage = File('lib/core/storage/storage_location_service.dart')
        .readAsStringSync();

    expect(native, contains('"samePhysicalPdf" ->'));
    expect(native, contains('Os.fstat(descriptor.fileDescriptor)'));
    expect(native, contains('Os.stat(local.canonicalPath)'));
    expect(storage, contains("invokeMethod<bool>('samePhysicalPdf'"));
    expect(dart, contains("sourceType == 'phone_storage_recycle_bin'"));
    expect(dart, contains('await moveToTrash(archivedDocument);'));
    expect(dart, contains('await storage.samePhysicalPdf('));
  });

  test('Phone Move stays independent of Grid and only deletes after verification',
      () {
    final service = File(
      'lib/features/documents/data/phone_pdf_move_service.dart',
    ).readAsStringSync();
    final screen = File(
      'lib/features/documents/presentation/phone_storage_browser_screen.dart',
    ).readAsStringSync();

    expect(service, contains('await storage.sha256Pdf(destinationUri)'));
    expect(service, contains('await storage.deletePdf(sourceUri)'));
    expect(service.indexOf('await storage.deletePdf(sourceUri)'),
        greaterThan(service.indexOf('await storage.sha256Pdf(destinationUri)')));
    expect(screen.indexOf("value: 'move_phone'"),
        lessThan(screen.indexOf("value: 'move', child: Text('Move to Grid')")));
    expect(screen, contains('onMoveWithinPhone'));
  });
}
