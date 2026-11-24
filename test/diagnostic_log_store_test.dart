import 'dart:io';

import 'package:docs_grid/core/diagnostics/diagnostic_log_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory private;
  late Directory portable;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('docsgrid_diagnostics_test_');
    private = Directory(p.join(root.path, 'private'));
    portable = Directory(p.join(root.path, 'System', 'Logs'));
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('records actual failure code and stage in both local stores', () async {
    await portable.create(recursive: true);
    final store = DiagnosticLogStore.forTesting(
      privateDirectory: private, portableDirectory: portable,
    );
    await store.recordError('PDF folder recovery',
      PlatformException(code: 'STORAGE_ERROR', message: 'Permission denied'),
      occurrences: 81,
    );
    final privateFiles = private.listSync().whereType<File>().toList();
    final portableFiles = portable.listSync().whereType<File>().toList();
    expect(privateFiles, hasLength(1));
    expect(portableFiles, hasLength(1));
    final written = await portableFiles.single.readAsString();
    expect(written, contains('PDF folder recovery'));
    expect(written, contains('STORAGE_ERROR: Permission denied'));
    expect(written, contains('count=81'));
    final snapshot = await store.readRecent();
    expect(snapshot.portableAvailable, isTrue);
    expect(snapshot.eventCount, 1,
      reason: 'Mirrored log lines must appear only once in viewer.');
  });

  test('private fallback retains errors when shared Logs is not available', () async {
    final store = DiagnosticLogStore.forTesting(privateDirectory: private);
    await store.recordError('Backup restore',
      StateError('Could not verify backup'));
    final snapshot = await store.readRecent();
    expect(snapshot.portableAvailable, isFalse);
    expect(snapshot.text, contains('Backup restore'));
    expect(snapshot.text, contains('Could not verify backup'));
    expect(await private.exists(), isTrue);
  });

  test('redacts sensitive PDF names, URLs, and raw paths', () {
    final sanitized = DiagnosticLogStore.redact(
      PlatformException(code: 'STORAGE_ERROR',
        message: 'Cannot read file:///storage/emulated/0/Documents/Rajesh.pdf '
          'and content://com.android.documents/document/101 '
          'or My_Insurance.pdf, token=AbCDef123'),
    );
    expect(sanitized, contains('STORAGE_ERROR'));
    expect(sanitized, isNot(contains('Rajesh.pdf')));
    expect(sanitized, isNot(contains('My_Insurance.pdf')));
    expect(sanitized, isNot(contains('AbCDef123')));
    expect(sanitized, isNot(contains('content://')));
    expect(sanitized, isNot(contains('/storage/emulated')));
  });

  test('concurrent events are serialized and visible', () async {
    final store = DiagnosticLogStore.forTesting(privateDirectory: private);
    await Future.wait(List.generate(10,
        (i) => store.recordError('Recovery', StateError('Error $i'))));
    final snapshot = await store.readRecent();
    expect(snapshot.eventCount, 10);
    expect(snapshot.text, contains('Error 0'));
    expect(snapshot.text, contains('Error 9'));
  });

  test('old diagnostic files are expired without touching unrelated files', () async {
    await private.create(recursive: true);
    final old = File(p.join(private.path, 'docsgrid-errors-2020-01-01.log'));
    final unrelated = File(p.join(private.path, 'my_policy.pdf'));
    await old.writeAsString('old');
    await unrelated.writeAsString('important user data');
    final store = DiagnosticLogStore.forTesting(privateDirectory: private);
    await store.recordError('Restore', StateError('Test failure'));
    expect(await old.exists(), isFalse);
    expect(await unrelated.readAsString(), 'important user data');
  });
}
