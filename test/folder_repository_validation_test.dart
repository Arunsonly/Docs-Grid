import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FolderRepository.validateFolderName', () {
    test('trims a valid folder name', () {
      expect(FolderRepository.validateFolderName('  Insurance  '), 'Insurance');
    });

    test('rejects empty and traversal names', () {
      expect(() => FolderRepository.validateFolderName('   '), throwsArgumentError);
      expect(() => FolderRepository.validateFolderName('.'), throwsArgumentError);
      expect(() => FolderRepository.validateFolderName('..'), throwsArgumentError);
    });

    test('rejects path separators and null bytes', () {
      expect(() => FolderRepository.validateFolderName('a/b'), throwsArgumentError);
      expect(() => FolderRepository.validateFolderName(r'a\b'), throwsArgumentError);
      expect(() => FolderRepository.validateFolderName('bad${String.fromCharCode(0)}name'), throwsArgumentError);
    });
  });
}
