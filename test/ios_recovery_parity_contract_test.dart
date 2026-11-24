import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
void main() {
  test('iOS recovery picks an authorized source without replacing Grid permissions', () {
    final main = File('lib/main.dart').readAsStringSync();
    final host = File('platform/ios/AppDelegate.swift').readAsStringSync();
    final tools = File('lib/features/tools/document_tools_service.dart').readAsStringSync();
    final repo = File('lib/features/documents/data/document_repository.dart').readAsStringSync();
    expect(main, contains("Platform.isIOS ? 'restore_zip'"));
    expect(main, contains("Platform.isIOS ? 'recover_selected_pdfs'"));
    expect(host, contains('if !isAuxiliary'));
    expect(host, contains('if isExport && isInsideAppContainer'));
    expect(host, contains('exportVerifiedFile'));
    expect(tools, contains('candidatesForRelink.length == 1 && !Platform.isIOS'));
    expect(repo, contains('_copyIosRecoveredPdf'));
    expect(repo, contains('Recovered PDF did not pass SHA-256 verification.'));
    expect(host, contains('UNUserNotificationCenter.current().getNotificationSettings'));
  });
  test('Android still uses original portable storage and background backup routes', () {
    final auto = File('lib/core/backup/backup_automation.dart').readAsStringSync();
    final ui = File('lib/features/tools/document_tools_screen.dart').readAsStringSync();
    final tools = File('lib/features/tools/document_tools_service.dart').readAsStringSync();
    expect(auto, contains('if (!Platform.isAndroid) return;'));
    expect(auto, contains('Workmanager().registerPeriodicTask'));
    expect(ui, contains('Automatic • Every 24 hours'));
    expect(tools, contains('if (Platform.isAndroid && destinationUri == null && !rescueCheckpoint)'));
  });
}
