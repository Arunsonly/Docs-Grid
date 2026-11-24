import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Settings hides redundant storage and recovery actions', () {
    final source = File('lib/main.dart').readAsStringSync();
    final settings = source.substring(source.indexOf('class _SettingsScreenState'));
    expect(settings, isNot(contains('Choose storage location')));
    expect(settings, isNot(contains('Recover previous installation')));
    expect(settings, isNot(contains("Text('Diagnostics')")));
    expect(settings, contains("Text('Backup & Recovery'"));
    expect(settings, contains("DocumentToolsScreen(section: 'backup_restore')"));
    expect(settings, contains('checkStorageAccess()'));
    expect(source, contains('_offerRestoreOnFirstLaunch()'));
    final recovery = File('lib/features/tools/document_tools_screen.dart').readAsStringSync();
    // The consolidated Backup & Recovery screen uses the newer card layout.
    // Assert the real entry points and handlers, not the retired button label.
    expect(recovery, contains("Text('Restore Backup')"));
    expect(recovery, contains("onTap: _busy ? null : () => _restoreBackup()"));
    expect(recovery, contains("Text('Emergency Recovery')"));
    expect(recovery, contains('onTap: _busy ? null : _showEmergencyRecovery'));
    expect(recovery, contains("Text('PDF folder')"));
    expect(recovery, contains("case 'pdf': await _recoverSelectedPdfFolder();"));
    expect(recovery, contains('BackupRestoreMode.fullReplacement'));
    expect(recovery, contains('BackupRestoreMode.selective'));
    expect(recovery, contains('BackupRestoreMode.merge'));
  });
}
