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

    test('rejects control characters and names longer than 255 characters', () {
      expect(
        () => FolderRepository.validateFolderName('bad\nname'),
        throwsArgumentError,
      );
      expect(
        () => FolderRepository.validateFolderName(List.filled(256, 'x').join()),
        throwsArgumentError,
      );
      expect(
        FolderRepository.validateFolderName(List.filled(255, 'x').join()),
        hasLength(255),
      );
    });

    test('rejects path separators and null bytes', () {
      expect(() => FolderRepository.validateFolderName('a/b'), throwsArgumentError);
      expect(() => FolderRepository.validateFolderName(r'a\b'), throwsArgumentError);
      expect(() => FolderRepository.validateFolderName('bad${String.fromCharCode(0)}name'), throwsArgumentError);
    });
  });
}
