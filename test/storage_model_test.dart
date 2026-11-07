import 'package:docs_grid/features/documents/data/document_repository.dart';
import 'package:docs_grid/features/folders/domain/folder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Folder maps its persisted platform storage URI', () {
    final folder = Folder.fromMap({
      'id': 'folder-1',
      'name': 'Insurance',
      'parent_id': 'parent-1',
      'storage_uri_or_relative_path': 'content://provider/tree/root/document/folder',
      'created_at': '2026-11-07T08:00:00.000Z',
      'updated_at': '2026-11-07T08:30:00.000Z',
    });

    expect(folder.id, 'folder-1');
    expect(folder.parentId, 'parent-1');
    expect(folder.storageUri, startsWith('content://'));
  });

  test('Document record retains an iOS Files URL as its canonical location', () {
    final document = DocumentRecord.fromMap({
      'id': 'document-1',
      'name': 'Policy',
      'storage_uri': 'file:///private/var/mobile/Containers/Shared/Policy.pdf',
      'size_bytes': 2048,
      'created_at': '2026-11-07T08:00:00.000Z',
      'metadata_json': '{}',
      'category_id': null,
      'category_name': null,
      'tag_names': null,
      'folder_id': 'folder-1',
    });

    expect(document.storagePath, startsWith('file://'));
    expect(document.folderId, 'folder-1');
    expect(document.sizeBytes, 2048);
  });
}
