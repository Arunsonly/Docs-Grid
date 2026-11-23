import 'package:docs_grid/features/tools/recovery_result_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unchanged snapshot reports already up to date, not newly recovered', () {
    final result = RecoveryResultData.fromSnapshot({
      'folders': 1,
      'documentsAdded': 0,
      'documentsLinked': 0,
      'pdfsMissing': 0,
      'categories': 8,
      'tags': 0,
      'documentTags': 0,
      'reminders': 0,
      'activity': 0,
      'ocrIndexes': 0,
      'settings': 0,
    }, {
      'added': 0, 'relinked': 0, 'duplicates': 1,
      'failed': 0, 'folders': 0,
    });
    expect(result.kind, RecoveryResultKind.upToDate);
    expect(result.title, 'Already up to date');
    expect(result.details, contains('folder records: 1'));
    expect(result.details, contains('categories: 8'));
    expect(result.details, contains('not necessarily newly created'));
    expect(result.metrics.first.value, 0);
  });

  test('a PDF scan separates newly registered, relinked and duplicates', () {
    final result = RecoveryResultData.fromPdfFolder({
      'added': 5, 'relinked': 2, 'duplicates': 100,
      'failed': 0, 'folders': 0,
    });
    expect(result.kind, RecoveryResultKind.recovered);
    expect(result.metrics[0].value, 3);
    expect(result.metrics[1].value, 2);
    expect(result.metrics[2].value, 100);
    expect(result.metrics[3].value, 0);
  });

  test('81 errors and zero recovered PDFs are a failure, not success', () {
    final result = RecoveryResultData.fromPdfFolder({
      'added': 0, 'relinked': 0, 'duplicates': 0,
      'failed': 81, 'folders': 0,
    }, failureReasons: '81× Reading source PDF checksum — Permission denied');
    expect(result.kind, RecoveryResultKind.failed);
    expect(result.metrics[3].value, 81);
    expect(result.details, contains('Permission denied'));
  });

  test('a scan with successes and failures is only partially completed', () {
    final result = RecoveryResultData.fromPdfFolder({
      'added': 7, 'relinked': 1, 'duplicates': 30,
      'failed': 2, 'folders': 1,
    });
    expect(result.kind, RecoveryResultKind.partial);
    expect(result.metrics[0].value, 6);
    expect(result.metrics[1].value, 1);
  });

  test('scan without files or failures does not claim any PDF was restored', () {
    final result = RecoveryResultData.fromPdfFolder({
      'added': 0, 'relinked': 0, 'duplicates': 0,
      'failed': 0, 'folders': 0,
    });
    expect(result.kind, RecoveryResultKind.noPdfs);
  });

  test('metadata retained with failed extra scan is partial, not total failure',
      () {
    final result = RecoveryResultData.fromSnapshot({
      'folders': 1, 'categories': 8,
      'documentsAdded': 0, 'documentsLinked': 0,
    }, {
      'added': 0, 'duplicates': 0, 'failed': 0, 'folders': 0,
    }, scanWarning: 'Storage permission denied');
    expect(result.kind, RecoveryResultKind.partial);
    expect(result.details, contains('Storage permission denied'));
  });

  test('database-only ZIP restore with zero PDF payloads is not a failed restore',
      () {
    final result = RecoveryResultData.fromArchive(0);
    expect(result.kind, isNot(RecoveryResultKind.failed));
    expect(result.subtitle, contains('Database restore completed'));
  });

  test('archive with extra scan failures is partial even after restoring PDFs',
      () {
    final result = RecoveryResultData.fromArchive(2, scanned: {
      'added': 1, 'relinked': 1, 'duplicates': 4, 'failed': 3,
    });
    expect(result.kind, RecoveryResultKind.partial);
    expect(result.metrics[0].value, 2);
    expect(result.metrics[1].value, 1);
    expect(result.metrics[2].value, 0);
    expect(result.metrics[3].value, 3);
  });

  testWidgets('only concise result is visible until View details is pressed',
      (tester) async {
    final outcome = RecoveryResultData.fromSnapshot({
      'folders': 1, 'documentsAdded': 0, 'documentsLinked': 0,
      'pdfsMissing': 0, 'categories': 8,
    }, {
      'added': 0, 'relinked': 0, 'duplicates': 1, 'failed': 0,
      'folders': 0,
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) => ElevatedButton(
          child: const Text('Show report'),
          onPressed: () => showRecoveryResultDialog(context, outcome),
        )),
      ),
    ));
    await tester.tap(find.text('Show report'));
    await tester.pumpAndSettle();
    expect(find.text('Already up to date'), findsOneWidget);
    expect(find.text('View details'), findsOneWidget);
    expect(find.byKey(const ValueKey('recovery-result-details')), findsNothing);
    await tester.tap(find.text('View details'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recovery-result-details')), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Already up to date'), findsNothing);
  });
}
