import 'dart:async';
import 'dart:io';

import 'package:docs_grid/features/tools/backup_chain.dart';
import 'package:docs_grid/features/tools/document_tools_screen.dart';
import 'package:docs_grid/features/tools/document_tools_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeArchive implements File {
  @override
  String get path => '/fake/DocsGrid/Backups/Full/DocsGrid_full.zip';
  @override
  Future<int> length() async => 120;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBackupService extends DocumentToolsService {
  @override
  Future<Map<String, int>> fullBackupPreview() async => {
    'documents': 10, 'folders': 3, 'categories': 8,
    'tags': 2, 'reminders': 1, 'pdfBytes': 100,
  };
  final Completer<List<BackupChainUsage>> slowOptionalRecount =
      Completer<List<BackupChainUsage>>();
  int usageCalls = 0;
  int created = 0;
  final List<String> stages = [];

  @override
  Future<List<BackupChainUsage>> manualBackupUsage() {
    usageCalls++;
    // Initial counter succeeds. Recount after the verified independent ZIP stalls.
    if (usageCalls >= 2) return slowOptionalRecount.future;
    return Future.value(<BackupChainUsage>[]);
  }

  @override
  Future<File> createStandaloneFullBackup({
    void Function(int, int)? onProgress,
    void Function(String)? onStage,
  }) async {
    created++;
    onStage?.call('Saving preferences and database metadata…');
    stages.add('metadata');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    onStage?.call('Verifying ZIP and checksums…');
    stages.add('verification');
    return _FakeArchive();
  }
}

void main() {
  testWidgets('backup success is visible even if optional storage recount stalls',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final service = _FakeBackupService();
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DocumentToolsScreen(
          service: service,
          section: 'backup_restore',
          forceAndroidBackupForTesting: true,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Backup privacy'), findsNothing);
    expect(find.text('Automatic metadata protection · manual PDF backups'),
        findsNothing);
    expect(find.text('Full Backup'), findsOneWidget);
    expect(find.text('Restore Backup'), findsOneWidget);
    expect(find.text('Database Backup'), findsOneWidget);
    expect(find.text('Emergency Recovery'), findsOneWidget);
    // Logs are app-private and not a UI item.
    expect(find.text('View error logs'), findsNothing);

    await tester.tap(find.text('Create Backup'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Create Full Backup'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog),
        matching: find.text('Create Backup')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Backup Successful'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(service.created, 1);
    expect(service.stages, containsAllInOrder(['metadata', 'verification']));
    expect(service.usageCalls, 2);
    expect(find.textContaining('Verified backup created: DocsGrid_full.zip'),
        findsOneWidget);
    // A blocked count does not keep Create Backup disabled.
    final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Create Backup'));
    expect(button.onPressed, isNotNull);

    // Allow the fake recount to finish so the test leaves no hanging future.
    service.slowOptionalRecount.complete(
      <BackupChainUsage>[const BackupChainUsage('DocsGrid_full.zip', 120, 1)]);
    await tester.pumpAndSettle();
    expect(find.textContaining('Verified backup created:'), findsOneWidget);
    expect(find.textContaining('1 ZIP files'), findsOneWidget);
  });
}
