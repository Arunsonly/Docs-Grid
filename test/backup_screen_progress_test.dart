import 'dart:async';
import 'dart:io';

import 'package:docs_grid/features/tools/backup_chain.dart';
import 'package:docs_grid/features/tools/document_tools_screen.dart';
import 'package:docs_grid/features/tools/document_tools_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBackupService extends DocumentToolsService {
  final Completer<List<BackupChainUsage>> slowOptionalRecount =
      Completer<List<BackupChainUsage>>();
  int usageCalls = 0;
  int created = 0;
  final List<String> stages = [];

  @override
  Future<List<BackupChainUsage>> manualBackupUsage() {
    usageCalls++;
    // First two calls: initial UI counter and the pre-create chain decision.
    // Recount after the validated output is deliberately stuck.
    if (usageCalls >= 3) return slowOptionalRecount.future;
    return Future.value(<BackupChainUsage>[]);
  }

  @override
  Future<File> createManualBackup({
    void Function(int, int)? onProgress,
    void Function(String)? onStage,
    bool newFull = false,
  }) async {
    created++;
    onStage?.call('Saving preferences and database metadata…');
    stages.add('metadata');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    onStage?.call('Verifying ZIP and checksums…');
    stages.add('verification');
    return File('/fake/DocsGrid/Backups/Full/A001/A001.zip');
  }
}

void main() {
  testWidgets('backup success is visible even if optional storage recount stalls',
      (tester) async {
    final service = _FakeBackupService();
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
    expect(find.text('Restore backup'), findsOneWidget);

    await tester.tap(find.text('Create Backup'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump();

    expect(service.created, 1);
    expect(service.stages, containsAllInOrder(['metadata', 'verification']));
    expect(service.usageCalls, 3);
    expect(find.textContaining('Verified backup created: A001/A001.zip'),
        findsOneWidget);
    // A blocked count does not keep Create Backup disabled.
    final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Create Backup'));
    expect(button.onPressed, isNotNull);

    // Allow the fake recount to finish so the test leaves no hanging future.
    service.slowOptionalRecount.complete(
      <BackupChainUsage>[const BackupChainUsage('A001', 120, 1)]);
    await tester.pumpAndSettle();
    expect(find.textContaining('Verified backup created:'), findsOneWidget);
    expect(find.textContaining('1 ZIP files'), findsOneWidget);
  });
}
