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

  test('new Android installs use Internal Storage/DocsGrid without moving legacy data', () {
    expect(workflow, contains('applicationId = "com.docsgrid.mobile"'));
    expect(native, contains('val preferredRoot = java.io.File(internalRoot, "DocsGrid").canonicalFile'));
    expect(native, contains('val previousRoot = java.io.File(mediaRoot, packageName).canonicalFile'));
    expect(native, contains('existingSavedRoot != null && existingSavedRoot.isDirectory'));
    expect(native, contains('previousRoot.isDirectory &&'));
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
    expect(native, contains(r'normalized.startsWith("$activeManagedRoot/")'));
    expect(native, contains('normalized == activeManagedRoot'));
    // Central Dart boundary guards both selected SAF and actual file://
    // managed roots; recursion never descends into its excluded tree.
    expect(storage, contains('GridStorageBoundary? excludeGrid'));
    expect(storage, contains('excludeGrid?.isManagedPath(path,'));
    expect(native, contains('managedPrimaryRelative'));
    expect(native, contains('normalized.startsWith("$managedPrimaryRelative/")'));
    // Old Grid paths stay excluded after a user selects the new root.
    expect(native, contains('normalized.startsWith("android/media/com.docsgrid/")'));
    final boundary = File('lib/core/storage/grid_storage_boundary.dart')
        .readAsStringSync();
    expect(boundary, contains("'android/media/com.docsgrid.mobile'"));
    expect(boundary, contains("'android/media/com.docsgrid'"));
  });

  test('existing recovery folder picker still accepts both historical names', () {
    expect(native, contains('selectedName.equals(packageName, ignoreCase = true)'));
    expect(native, contains('selectedName.equals("com.docsgrid", ignoreCase = true)'));
    expect(native, contains('selectedName.equals("DocsGrid", ignoreCase = true)'));
    expect(native, contains('findChildUri(uri, packageName)'));
    expect(native, contains('findChildUri(uri, "com.docsgrid")'));
    expect(native, contains('findChildUri(uri, "DocsGrid")'));
    expect(native, contains('Recovery is read-only'));
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
