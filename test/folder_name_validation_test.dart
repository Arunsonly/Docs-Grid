import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FolderRepository.validateFolderName', () {
    test('trims surrounding whitespace and accepts a normal segment', () {
      expect(FolderRepository.validateFolderName('  Insurance  '), 'Insurance');
    });

    test('rejects empty, dot and dot-dot segments', () {
      for (final value in ['', '   ', '.', '..']) {
        expect(() => FolderRepository.validateFolderName(value), throwsArgumentError);
      }
    });

    test('rejects both platform path separators', () {
      for (final value in ['parent/child', r'parent\child']) {
        expect(() => FolderRepository.validateFolderName(value), throwsArgumentError);
      }
    });
  });
}
