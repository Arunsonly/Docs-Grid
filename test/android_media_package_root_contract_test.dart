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
    expect(native, contains('listOf("My Files", "System", "Documents",'));
    expect(native, contains('"Folders", "Database", "Recovery").any'));
    expect(native, contains('val myFiles = java.io.File(root, "My Files")'));
    expect(native, contains('val unfiled = java.io.File(myFiles, "Unfiled")'));
    expect(native, contains('val folders = java.io.File(myFiles, "Folders")'));
    expect(native, contains('val system = java.io.File(root, "System")'));
    expect(native, contains('val recoveryFolder = java.io.File(system, "Recovery")'));
    expect(native, contains('val backupsFolder = java.io.File(system, "Backups")'));
    expect(native, isNot(contains('val root = java.io.File(mediaRoot, "com.docsgrid")')));
  });

  test('operational folders are private for both local and SAF storage', () {
    for (final name in ['Cache', 'Thumbnails', 'Temp', 'Logs', 'Exports']) {
      expect(native, isNot(contains('java.io.File(system, "$name")')));
      expect(native, isNot(contains('ensureDirectory(systemUri, "$name")')));
    }
    expect(native, contains('selectedLocations.putAll(privateOperationalLocations())'));
    expect(native, contains(') + privateOperationalLocations())'));
    expect(native, contains('java.io.File(filesDir, "docsgrid")'));
    expect(native, contains('java.io.File(cacheDir, "docsgrid/Temp")'));
    expect(native, contains('pruneEmptyLegacyOperationalFolders(system)'));
    expect(native, contains('directory.list()?.isEmpty() == true'));
    expect(native, contains('directory.canonicalFile == directory.absoluteFile'));
    final logs = File('lib/core/diagnostics/diagnostic_log_store.dart')
        .readAsStringSync();
    expect(logs, contains('_defaultPrivateDirectory, () async => null,'));
    expect(logs, isNot(contains("locations['logsUri']")));
    final tools = File('lib/features/tools/document_tools_service.dart')
        .readAsStringSync();
    expect(tools, contains('final temp = await getTemporaryDirectory();'));
    expect(tools, contains('final temporaryDirectory = Platform.isAndroid || Platform.isIOS'));
    expect(tools, contains('? await getTemporaryDirectory() : Directory.systemTemp;'));
    expect(tools, isNot(contains("['tempUri']")));
  });

  test('local Grid checks do not enumerate folder children or use the scan pool', () {
    expect(native, contains('gridDirectoryExecutor.execute'));
    expect(native, contains('gridDirectoryExecutor.shutdown()'));
    final begin = native.indexOf('"checkLocalGridDirectory" -> {');
    final end = native.indexOf('"listDirectory" -> {', begin);
    final check = native.substring(begin, end);
    expect(check, contains('fileForUri(uri)'));
    expect(check, contains('Os.stat(directory.path)'));
    expect(check, contains('Os.access(directory.path'));
    expect(check, isNot(contains('listFiles')));
    expect(storage, contains('Future<void> verifyGridDirectory(String uri)'));
    final repo = File('lib/features/folders/data/folder_repository.dart')
        .readAsStringSync();
    expect(repo, contains('await storage.verifyGridDirectory(uri);'));
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
    expect(native, contains(r'normalized.startsWith("$managedPrimaryRelative/")'));
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

  test('direct Internal Storage/DocsGrid is protected from Phone Move', () {
    for (final managed in [
      'file:///storage/emulated/0/DocsGrid',
      'file:///storage/emulated/0/DocsGrid/My%20Files/Folders/A',
      'content://com.android.externalstorage.documents/tree/primary%3ADocsGrid',
    ]) {
      expect(StorageLocationService.isDirectInternalGridRootUri(managed), isTrue);
      expect(StorageLocationService.isRestrictedPhoneMoveDestination(managed),
          isTrue);
    }
    for (final unrelated in [
      'file:///storage/emulated/0/DocsGridExtra',
      'file:///storage/1234-5678/DocsGrid',
      'file:///storage/emulated/0/Download/DocsGrid',
    ]) {
      expect(StorageLocationService.isDirectInternalGridRootUri(unrelated),
          isFalse);
    }
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
