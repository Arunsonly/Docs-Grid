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
    expect(recovery, contains("Text('Restore backup')"));
    expect(recovery, contains("Text('PDF folder')"));
  });
}
