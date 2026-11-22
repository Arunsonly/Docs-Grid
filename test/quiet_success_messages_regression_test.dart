import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Grid never blocks work with routine successful-action snackbars', () {
    final source = File('lib/features/folders/presentation/folders_screen.dart')
        .readAsStringSync();
    for (final message in <String>[
      'Folder created.',
      'Folder renamed.',
      'Folder order saved.',
      'Reminder saved for this PDF.',
      r'Moved ${selected.length} folder(s).',
      r'Moved ${selected.length} folder(s) and',
    ]) {
      expect(source, isNot(contains(message)), reason: 'Unexpected routine status: $message');
    }
    expect(source, contains("if (result.duplicates > 0 || result.failed > 0)"));
    expect(source, contains("Could not save folder order"));
    expect(source, contains("Could not move folders"));
  });

  test('Home and Phone avoid routine successful-action snackbars', () {
    final source = File('lib/features/documents/presentation/documents_screen.dart')
        .readAsStringSync();
    for (final message in <String>[
      'Recent cleared. PDF files were not deleted.',
      'Added to Star.',
      'Removed from Star.',
      'Rename completed.',
      'PDF relinked and verified successfully.',
      'Phone reference re-linked.',
      'Reminder saved for this PDF.',
      'Moved \$name to Grid. It is now in Grid Recent.',
      'PDF renamed.',
    ]) {
      expect(source, isNot(contains("'$message'")),
          reason: 'Unexpected routine status: $message');
    }
    expect(source, contains("if (failures.isNotEmpty)"));
    expect(source, contains('shortcutWarning != null'));
    expect(source, contains('This PDF already exists in Grid.'));
    expect(source, contains('Phone original was kept.'));
  });

  test('App settings/import show success via UI, not bottom notifications', () {
    final source = File('lib/main.dart').readAsStringSync();
    final permissions = File('lib/features/reminders/presentation/reminders_screen.dart')
        .readAsStringSync();
    expect(source, isNot(contains('Saved in DocsGrid.')));
    expect(source, isNot(contains('Storage folder selected:')));
    expect(source, isNot(contains('Library copy completed:')));
    expect(source, contains("title: const Text('Already in DocsGrid')"));
    expect(source, contains('No duplicate was added.'));
    expect(source, contains('Library copy stopped safely'));
    expect(permissions, isNot(contains('Notification permission request completed.')));
    expect(permissions, contains('Notifications are off.'));
  });
}
