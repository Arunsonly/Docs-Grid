import 'package:docs_grid/features/tools/document_tools_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('legacy recovery is restricted to DocsGrid-managed library folders', () {
    final root = p.join(
      'storage',
      'emulated',
      '0',
      'Android',
      'media',
      'DocsGrid',
    );

    final roots = DocumentToolsService.legacyManagedRecoveryPaths(root);

    expect(
      roots.map((item) => item.path).toList(),
      [
        p.join(root, 'My Files', 'Unfiled'),
        p.join(root, 'My Files', 'Folders'),
        p.join(root, 'Documents'),
        p.join(root, 'Folders'),
        p.join(root, 'Unfiled'),
      ],
    );
    expect(
      roots.map((item) => item.preserveFolders).toList(),
      [false, true, false, true, false],
    );

    // General Phone locations are intentionally not part of the recovery
    // whitelist. Their PDFs remain browseable in Phone until explicitly moved.
    expect(roots.any((item) => item.path.contains('Download')), isFalse);
    expect(roots.any((item) => item.path.contains('WhatsApp')), isFalse);
    expect(roots.any((item) => item.path.contains('Documents/Android')), isFalse);
  });
}
