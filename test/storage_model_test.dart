import 'package:docs_grid/core/storage/storage_location_service.dart';
import 'package:docs_grid/features/documents/data/document_repository.dart';
import 'package:docs_grid/features/folders/domain/folder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Storage access status', () {
    test('recognises an available external folder', () {
      expect(
        StorageLocationService.normalizeAccessStatus({
          'status': 'available',
          'message': 'Storage folder is accessible.',
          'name': 'Documents',
        }),
        {
          'status': 'available',
          'message': 'Storage folder is accessible.',
          'name': 'Documents',
        },
      );
    });

    test('recognises a revoked permission and preserves repair guidance', () {
      expect(
        StorageLocationService.normalizeAccessStatus({
          'status': 'revoked',
          'message': 'Permission was revoked. Select the folder again.',
        }),
        {
          'status': 'revoked',
          'message': 'Permission was revoked. Select the folder again.',
        },
      );
    });

    test('distinguishes a not-configured folder', () {
      expect(
        StorageLocationService.normalizeAccessStatus({
          'status': 'not_configured',
          'message': 'No folder selected.',
        })['status'],
        'not_configured',
      );
    });

    test('fails closed for missing or unknown native status values', () {
      expect(
        StorageLocationService.normalizeAccessStatus(null),
        {
          'status': 'unknown',
          'message': 'Storage access could not be verified.',
        },
      );
      expect(
        StorageLocationService.normalizeAccessStatus({
          'status': 'anything_else',
          'message': '',
        }),
        {
          'status': 'unknown',
          'message': 'Storage access could not be verified.',
        },
      );
    });
  });

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
