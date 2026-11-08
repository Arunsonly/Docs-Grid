import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('FolderRepository.remapPrivateDocumentPath', () {
    test('preserves nested relative paths when an ancestor is renamed', () {
      final oldFolder = p.join('DocsGrid', 'PDFs', 'Insurance', 'Motor');
      final newFolder = p.join('DocsGrid', 'PDFs', 'Insurance', 'Vehicles');
      final oldFile = p.join(oldFolder, 'Nested', 'Policy.pdf');

      expect(
        FolderRepository.remapPrivateDocumentPath(
          oldFolderPath: oldFolder,
          newFolderPath: newFolder,
          documentUri: oldFile,
        ),
        p.join(newFolder, 'Nested', 'Policy.pdf'),
      );
    });

    test('does not rewrite provider URIs', () {
      expect(
        FolderRepository.remapPrivateDocumentPath(
          oldFolderPath: '/private/DocsGrid/PDFs/Motor',
          newFolderPath: '/private/DocsGrid/PDFs/Vehicles',
          documentUri: 'content://provider/document/123',
        ),
        isNull,
      );
      expect(
        FolderRepository.remapPrivateDocumentPath(
          oldFolderPath: '/private/DocsGrid/PDFs/Motor',
          newFolderPath: '/private/DocsGrid/PDFs/Vehicles',
          documentUri: 'file:///provider/Policy.pdf',
        ),
        isNull,
      );
    });

    test('does not rewrite paths outside the renamed folder', () {
      expect(
        FolderRepository.remapPrivateDocumentPath(
          oldFolderPath: '/private/DocsGrid/PDFs/Motor',
          newFolderPath: '/private/DocsGrid/PDFs/Vehicles',
          documentUri: '/private/DocsGrid/PDFs/Health/Policy.pdf',
        ),
        isNull,
      );
    });
  });
}
