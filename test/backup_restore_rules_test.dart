import 'package:docs_grid/features/tools/backup_folder_graph_validator.dart';
import 'package:docs_grid/features/tools/backup_schema_compatibility.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BackupSchemaCompatibility', () {
    test('accepts the current database schema version', () {
      expect(
        () => BackupSchemaCompatibility.requireSupported(7),
        returnsNormally,
      );
    });

    test('rejects a backup created by a newer database schema', () {
      expect(
        () => BackupSchemaCompatibility.requireSupported(8),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects invalid schema versions', () {
      expect(
        () => BackupSchemaCompatibility.requireSupported(0),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('BackupFolderGraphValidator', () {
    test('accepts a nested folder hierarchy', () {
      expect(
        () => BackupFolderGraphValidator.validate([
          {'id': 'root', 'parent_id': null},
          {'id': 'child', 'parent_id': 'root'},
          {'id': 'grandchild', 'parent_id': 'child'},
        ]),
        returnsNormally,
      );
    });

    test('rejects a missing parent', () {
      expect(
        () => BackupFolderGraphValidator.validate([
          {'id': 'child', 'parent_id': 'missing'},
        ]),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects a parent cycle', () {
      expect(
        () => BackupFolderGraphValidator.validate([
          {'id': 'first', 'parent_id': 'second'},
          {'id': 'second', 'parent_id': 'first'},
        ]),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects duplicate folder IDs', () {
      expect(
        () => BackupFolderGraphValidator.validate([
          {'id': 'same', 'parent_id': null},
          {'id': 'same', 'parent_id': null},
        ]),
        throwsA(isA<StateError>()),
      );
    });
  });
}
