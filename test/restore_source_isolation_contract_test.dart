import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('old source picker cannot replace live DocsGrid storage preferences', () {
    final android = File('platform/android/MainActivity.kt').readAsStringSync();
    final start = android.indexOf('if (recoveryOnly) {');
    final end = android.indexOf('// Reuse the selected DocsGrid directory', start);
    expect(start, greaterThan(0));
    expect(end, greaterThan(start));
    final sourceOnly = android.substring(start, end);
    expect(sourceOnly, contains('"databaseUri" to database.toString()'));
    expect(sourceOnly, contains('"libraryUri" to folders.toString()'));
    expect(sourceOnly, isNot(contains('.putString("docsgrid_uri"')));
    expect(sourceOnly, isNot(contains('.putString("database_uri"')));
    expect(sourceOnly, isNot(contains('.putString("folders_uri"')));
    expect(sourceOnly, isNot(contains('.putString("recovery_uri"')));
    expect(sourceOnly, isNot(contains('.apply()')));
  });

  test('onboarding does not offer a generic existing-folder restore inside ZIP menu', () {
    final ui = File('lib/features/tools/document_tools_screen.dart')
        .readAsStringSync();
    expect(ui, isNot(contains("title: const Text('Existing DocsGrid folder')")));
    expect(ui, contains('restore_selected_portable'));
    expect(ui, contains('sourceLocations: recoverySource'));
  });

  test('manual backup still refuses SAF root and preserves 2GiB ceiling', () {
    final service = File('lib/features/tools/document_tools_service.dart')
        .readAsStringSync();
    expect(service, contains("!rootUri.startsWith('file://')"));
    final limits = File('lib/features/tools/backup_archive_limits.dart')
        .readAsStringSync();
    expect(limits, contains('2 * 1024 * 1024 * 1024'));
  });
}
