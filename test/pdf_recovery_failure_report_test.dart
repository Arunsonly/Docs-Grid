import 'package:docs_grid/features/tools/pdf_recovery_failure_report.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all 81 failed PDFs show the actual native cause and stage', () {
    final report = PdfRecoveryFailureReport();
    for (var i = 0; i < 81; i++) {
      report.record('Reading source PDF checksum',
          PlatformException(code: 'STORAGE_ERROR', message: 'Permission denied'));
    }
    expect(report.totalFailures, 81);
    expect(report.summary,
        '81× Reading source PDF checksum — STORAGE_ERROR: Permission denied');
  });

  test('different stages are not incorrectly grouped', () {
    final report = PdfRecoveryFailureReport();
    report.record('Preparing Grid destination folder',
        StateError('Allow storage access or choose a folder before creating folders.'));
    report.record('Importing verified PDF into Grid',
        StateError('Allow storage access or choose a folder before recovering PDFs.'));
    expect(report.totalFailures, 2);
    expect(report.summary, contains('Preparing Grid destination folder'));
    expect(report.summary, contains('Importing verified PDF into Grid'));
    expect(report.summary, contains('Allow storage access'));
  });

  test('source name and stack traces are not required for failure reporting', () {
    final report = PdfRecoveryFailureReport();
    report.record('Scanning PDF folder',
        PlatformException(code: 'STORAGE_ERROR', message: 'File not found\nStacktrace line'));
    expect(report.totalFailures, 1);
    expect(report.summary, isNot(contains('\n')));
    expect(report.summary, contains('File not found Stacktrace line'));
  });

  test('large provider error text is bounded for display', () {
    final report = PdfRecoveryFailureReport();
    report.record('Importing verified PDF into Grid',
        PlatformException(code: 'STORAGE_ERROR', message: 'a' * 1200));
    expect(report.summary.length, lessThan(350));
  });

  test('empty report stays empty', () {
    final report = PdfRecoveryFailureReport();
    expect(report.totalFailures, 0);
    expect(report.summary, isEmpty);
  });
}
