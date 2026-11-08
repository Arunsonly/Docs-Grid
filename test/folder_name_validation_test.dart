import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FolderRepository.validateFolderName', () {
    test('trims a valid folder name', () {
      expect(FolderRepository.validateFolderName('  Insurance  '), 'Insurance');
    });

    test('rejects empty names and dot path segments', () {
      expect(() => FolderRepository.validateFolderName('  '), throwsArgumentError);
      expect(() => FolderRepository.validateFolderName('.'), throwsArgumentError);
      expect(() => FolderRepository.validateFolderName('..'), throwsArgumentError);
    });

    test('rejects path separators', () {
      expect(() => FolderRepository.validateFolderName('parent/child'), throwsArgumentError);
      expect(() => FolderRepository.validateFolderName(r'parent\child'), throwsArgumentError);
    });
  });
}
