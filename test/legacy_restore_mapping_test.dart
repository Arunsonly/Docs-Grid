import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes the legacy timestamp and hashed folder layout', () {
    expect(FolderRepository.isLegacyRestoreStorageUri(
      '/storage/emulated/0/Android/media/com.docsgrid/My Files/Folders/'
      'Restored_1794904040961709/Insurance_360d1ef9'), isTrue);
    expect(FolderRepository.isLegacyRestoreStorageUri(
      'file:///storage/emulated/0/Android/media/com.docsgrid/My%20Files/Folders/'
      'Restored_1794880642894193/Insurance_33672d83'), isTrue);
    expect(FolderRepository.isLegacyRestoreStorageUri(
      '/app/DocsGrid/Library/Folders/Restored_1794904040961709/'
      'Insurance_360d1ef9/Claims_abcdef12'), isTrue);
  });

  test('never labels normal or unrelated folders as legacy restore data', () {
    for (final path in [
      '/storage/DocsGrid/My Files/Folders/Insurance',
      '/storage/DocsGrid/My Files/Folders/Restored_1794904040961709',
      '/storage/Downloads/Restored_1794904040961709/Insurance_360d1ef9',
      'content://provider/tree/primary%3ADocuments',
      '/storage/My Files/Folders/Restored_abc/Insurance_360d1ef9',
      '/storage/My Files/Folders/Restored_1794904040961709/Insurance',
    ]) {
      expect(FolderRepository.isLegacyRestoreStorageUri(path), isFalse,
          reason: 'Must not guess the identity of an unrelated physical folder.');
    }
  });
}
