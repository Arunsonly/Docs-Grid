import 'dart:io';

import 'package:docs_grid/core/storage/storage_location_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late String native;
  late String workflow;
  late String storage;
  setUpAll(() {
    native = File('platform/android/MainActivity.kt').readAsStringSync();
    workflow = File('.github/workflows/flutter-ci.yml').readAsStringSync();
    storage = File('lib/core/storage/storage_location_service.dart')
        .readAsStringSync();
  });

  test('the automatic Android/media folder always uses installed package ID', () {
    expect(workflow, contains('applicationId = "com.docsgrid.mobile"'));
    expect(native, contains('val root = java.io.File(mediaRoot, packageName)'));
    expect(native, contains('val myFiles = java.io.File(root, "My Files")'));
    expect(native, contains('val unfiled = java.io.File(myFiles, "Unfiled")'));
    expect(native, contains('val folders = java.io.File(myFiles, "Folders")'));
    expect(native, contains('val system = java.io.File(root, "System")'));
    expect(native, contains('val recoveryFolder = java.io.File(system, "Recovery")'));
    expect(native, contains('val backupsFolder = java.io.File(system, "Backups")'));
    expect(native, isNot(contains('val root = java.io.File(mediaRoot, "com.docsgrid")')));
  });

  test('Phone MediaStore and recursive browsing never duplicate new Grid files', () {
    expect(native, contains('val activeManagedRoot = "android/media/'));
    expect(native, contains('normalized.startsWith("$activeManagedRoot/")'));
    expect(native, contains('normalized == activeManagedRoot'));
    expect(storage, contains("path == 'Android/media/com.docsgrid.mobile'"));
    expect(storage, contains("path.startsWith('Android/media/com.docsgrid.mobile/')"));
    // Old Grid paths are excluded too, not treated as ordinary Phone PDFs.
    expect(native, contains('normalized.startsWith("android/media/com.docsgrid/")'));
    expect(storage, contains("path == 'Android/media/com.docsgrid'"));
  });

  test('existing recovery folder picker still accepts both historical names', () {
    expect(native, contains('selectedName.equals(packageName, ignoreCase = true)'));
    expect(native, contains('selectedName.equals("com.docsgrid", ignoreCase = true)'));
    expect(native, contains('selectedName.equals("DocsGrid", ignoreCase = true)'));
    expect(native, contains('findChildUri(uri, packageName)'));
    expect(native, contains('findChildUri(uri, "com.docsgrid")'));
    expect(native, contains('findChildUri(uri, "DocsGrid")'));
    expect(native, contains('Recovery selection is read-only'));
  });

  test('canonical classification handles local and SAF paths and rejects lookalikes', () {
    for (final path in [
      'file:///storage/emulated/0/Android/media/com.docsgrid.mobile',
      'file:///storage/emulated/0/Android/media/com.docsgrid.mobile/My%20Files/Folders/A.pdf',
      'content://com.android.externalstorage.documents/tree/primary%3AAndroid%2Fmedia%2Fcom.docsgrid.mobile',
    ]) {
      expect(StorageLocationService.isCanonicalPortableRootUri(path), isTrue,
          reason: path);
      expect(StorageLocationService.isLegacyDocsGridStorageLocation(path), isFalse,
          reason: path);
      expect(StorageLocationService.isRestrictedPhoneMoveDestination(path), isTrue,
          reason: path);
    }
    for (final old in [
      'file:///storage/emulated/0/Android/media/com.docsgrid/My%20Files/Folders/A.pdf',
      'file:///storage/emulated/0/Android/media/DocsGrid/Folders/A.pdf',
    ]) {
      expect(StorageLocationService.isCanonicalPortableRootUri(old), isFalse);
      expect(StorageLocationService.isLegacyDocsGridStorageLocation(old), isTrue);
      expect(StorageLocationService.isRestrictedPhoneMoveDestination(old), isTrue);
    }
    for (final wrong in [
      'file:///storage/emulated/0/Android/media/com.docsgrid.mobile_extra',
      'file:///storage/emulated/0/Android/media/com.docsgrid.mobiles',
      'file:///storage/emulated/0/Android/media/com.docsgrid/mobile',
    ]) {
      expect(StorageLocationService.isCanonicalPortableRootUri(wrong), isFalse);
    }
  });
}
