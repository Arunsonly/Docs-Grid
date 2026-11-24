import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late String service;
  late String ui;
  late String native;
  setUpAll(() {
    service = File('lib/features/tools/document_tools_service.dart')
        .readAsStringSync();
    ui = File('lib/features/tools/document_tools_screen.dart')
        .readAsStringSync();
    native = File('platform/android/MainActivity.kt').readAsStringSync();
  });

  test('preflight runs before parsing, expanding or writing ZIP PDF entries', () {
    final locked = service.indexOf('Future<int?> _restoreBackupLocked(');
    final preflight = service.indexOf('zipRestoreFileLocations()', locked);
    final decode = service.indexOf('final backup = await _decodeValidatedBackup', locked);
    final transaction = service.indexOf('await _createRestoreSafetyCheckpoint(', decode);
    expect(locked, greaterThanOrEqualTo(0));
    expect(preflight, greaterThan(locked));
    expect(decode, greaterThan(preflight));
    expect(transaction, greaterThan(decode));
  });

  test('preview rechecks the same destinations before ANY checkpoint or file copies', () {
    final preview = service.indexOf('if (confirmPlan != null && !await confirmPlan(preview)) return null;');
    final recheck = service.indexOf('final current = await StorageLocationService.instance.zipRestoreFileLocations()', preview);
    final safety = service.indexOf('await _createRestoreSafetyCheckpoint(', preview);
    final copy = service.indexOf("await File(stagedPath).copy(pendingFile.path)", preview);
    expect(recheck, greaterThan(preview));
    expect(safety, greaterThan(recheck));
    expect(copy, greaterThan(safety));
    expect(service, contains('current[\'documentsUri\'] != portableUnfiledUri'));
    expect(service, contains('current[\'libraryUri\'] != portableFoldersUri'));
  });

  test('ZIP restore still validates source and physical copies before database commit', () {
    expect(service, contains('BackupArchiveLimits.validate(zipFile)'));
    expect(service, contains('PortableSnapshotRowsValidator.validate('));
    expect(service, contains('await sha256.bind(pendingFile.openRead()).first'));
    expect(service, contains('PDF integrity check failed during restore.'));
    expect(service, contains("await writeJournal('rolledBack')"));
    expect(service, contains('await backup.dispose()'));
    expect(service, contains('BackupRestoreMode.fullReplacement'));
  });

  test('permission and chosen local folder are resolved without destructive fallback', () {
    expect(native, contains('"resolveZipRestoreFileLocations" ->'));
    expect(native, contains('selectedDocuments != prefs.getString("documents_uri", null)'));
    expect(native, contains('selectedLibrary != savedLibrary'));
    expect(native, contains('uri.authority != "com.android.externalstorage.documents"'));
    expect(native, contains('!documentId.startsWith("primary:", ignoreCase = true)'));
    expect(native, contains('directory.path.startsWith(sharedRoot.path + java.io.File.separator)'));
    expect(native, contains('!directory.isDirectory || !directory.canRead() || !directory.canWrite()'));
    expect(native, contains('Uri.fromFile(directory).toString()'));
    expect(native, contains('"RESTORE_LOCATION_CHANGED"'));
  });

  test('all ZIP restore cancellation points clear stale waiting messages', () {
    expect(ui, contains("if (source == 'zip' && platformFile == null) {"));
    expect(ui, contains("if (restoreMode == null || !mounted) {"));
    expect(ui, contains("if (selection == null || selection.isEmpty || !mounted) {"));
    expect(ui, contains("restored == null"));
    expect(ui, contains("Restore cancelled. Nothing was changed."));
    expect(ui, contains("then return and choose Restore again."));
  });

  test('UI keeps all three restore modes and ZIP selection; old folder stays in onboarding', () {
    // Existing-folder restoration was deliberately removed from the ordinary
    // ZIP restore sheet after it repointed the live backup root. The separate
    // onboarding/Settings picker still offers read-only old-data recovery.
    expect(ui, isNot(contains("if (source == 'folder')")));
    expect(ui, contains("case 'pdf': await _recoverSelectedPdfFolder();"));
    expect(ui, contains("case 'series': await _restoreBackup(source: 'series');"));
    expect(ui, contains("Future<void> _restoreBackup({String source = 'zip'})"));
    expect(ui, contains('restore_selected_portable'));
    expect(ui, contains('sourceLocations: recoverySource'));
    expect(ui, contains("allowedExtensions: ['zip']"));
    expect(ui, contains('BackupRestoreMode.merge'));
    expect(ui, contains('BackupRestoreMode.fullReplacement'));
    expect(ui, contains('BackupRestoreMode.selective'));
    expect(ui, contains('await _tools.restoreBackup('));
    expect(ui, contains('onProgress: (message)'));
    expect(ui, contains('requestAllFilesAccess()'));
  });
}
