import 'package:docs_grid/features/tools/backup_folder_graph_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BackupFolderGraphValidator', () {
    test('accepts a valid nested folder tree', () {
      expect(
        () => BackupFolderGraphValidator.validate([
          {'id': 'root', 'parent_id': null},
          {'id': 'child', 'parent_id': 'root'},
          {'id': 'grandchild', 'parent_id': 'child'},
        ]),
        returnsNormally,
      );
    });

    test('rejects cyclic parent references', () {
      expect(
        () => BackupFolderGraphValidator.validate([
          {'id': 'a', 'parent_id': 'b'},
          {'id': 'b', 'parent_id': 'a'},
        ]),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects missing parents', () {
      expect(
        () => BackupFolderGraphValidator.validate([
          {'id': 'child', 'parent_id': 'missing'},
        ]),
        throwsA(isA<StateError>()),
      );
    });

    test('handles deep folder trees without recursive stack growth', () {
      final folders = List<Map<String, Object?>>.generate(
        10000,
        (index) => {
          'id': 'folder_$index',
          'parent_id': index == 0 ? null : 'folder_${index - 1}',
        },
      );

      expect(
        () => BackupFolderGraphValidator.validate(folders),
        returnsNormally,
      );
    });

    test('rejects duplicate and empty IDs', () {
      expect(
        () => BackupFolderGraphValidator.validate([
          {'id': 'same', 'parent_id': null},
          {'id': 'same', 'parent_id': null},
        ]),
        throwsA(isA<StateError>()),
      );
      expect(
        () => BackupFolderGraphValidator.validate([
          {'id': ' ', 'parent_id': null},
        ]),
        throwsA(isA<StateError>()),
      );
    });
  });
}
