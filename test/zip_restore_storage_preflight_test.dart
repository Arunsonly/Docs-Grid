import 'package:docs_grid/core/storage/storage_location_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const selectedPrimarySAF = <String, String>{
    'documentsUri':
        'content://com.android.externalstorage.documents/tree/primary%3ADocsGrid/'
        'document/primary%3ADocsGrid%2FDocuments',
    'libraryUri':
        'content://com.android.externalstorage.documents/tree/primary%3ADocsGrid/'
        'document/primary%3ADocsGrid%2FFolders',
  };
  const expectedLocal = <String, String>{
    'documentsUri': 'file:///storage/emulated/0/DocsGrid/Documents',
    'libraryUri': 'file:///storage/emulated/0/DocsGrid/Folders',
  };

  test('selected local SAF folders reuse exactly their original file paths', () {
    final result = StorageLocationService.validateZipRestoreFileLocations(
      configured: selectedPrimarySAF,
      allFilesAccess: true,
      localEquivalent: expectedLocal,
    );
    expect(result, expectedLocal);
    expect(result['documentsUri'], isNot(contains('com.docsgrid/My Files')));
  });

  test('canonical file-backed folders keep their original destinations', () {
    const custom = {
      'documentsUri': 'file:///storage/emulated/0/Android/media/com.docsgrid/My%20Files/Unfiled',
      'libraryUri': 'file:///storage/emulated/0/Android/media/com.docsgrid/My%20Files/Folders',
    };
    expect(StorageLocationService.validateZipRestoreFileLocations(
      configured: custom,
      allFilesAccess: true,
    ), custom);
  });

  test('permission denied fails closed, even if stale file paths are cached', () {
    expect(() => StorageLocationService.validateZipRestoreFileLocations(
      configured: expectedLocal, allFilesAccess: false,
    ), throwsA(isA<StateError>().having(
      (error) => error.message.toString(), 'description',
      contains('currently disabled'),
    )));
  });

  test('granted permission cannot turn a cloud/USB/SD tree into a new library', () {
    for (final folder in [
      'content://com.google.android.apps.docs.storage/document/123',
      'content://com.android.externalstorage.documents/tree/1234-ABCD%3ADocsGrid',
      'content://com.android.externalstorage.documents/tree/primary%3ADocsGrid',
    ]) {
      expect(() => StorageLocationService.validateZipRestoreFileLocations(
        configured: {'documentsUri': folder, 'libraryUri': folder},
        allFilesAccess: true,
      ), throwsStateError);
    }
  });

  test('missing documents or folders are never silently replaced', () {
    for (final missing in [
      {'documentsUri': expectedLocal['documentsUri']!},
      {'libraryUri': expectedLocal['libraryUri']!},
      <String, String>{},
    ]) {
      expect(() => StorageLocationService.validateZipRestoreFileLocations(
        configured: missing, allFilesAccess: true,
      ), throwsStateError);
    }
  });

  test('untrusted non-file results and malformed file URIs fail closed', () {
    for (final malformed in [
      'content://provider/new_folder',
      'file://remotehost/folder',
      'file:///tmp/file?query=1',
      'file:///tmp/file#fragment',
      'https://host/path',
      'file:///',
    ]) {
      expect(() => StorageLocationService.validateZipRestoreFileLocations(
        configured: selectedPrimarySAF,
        allFilesAccess: true,
        localEquivalent: {
          'documentsUri': malformed,
          'libraryUri': expectedLocal['libraryUri']!,
        },
      ), throwsStateError, reason: 'Unsafe location: $malformed');
    }
  });

  test('Documents and Folders can never target the same physical directory', () {
    const duplicate = 'file:///storage/emulated/0/DocsGrid/Files';
    expect(() => StorageLocationService.validateZipRestoreFileLocations(
      configured: {
        'documentsUri': duplicate,
        'libraryUri': duplicate,
      },
      allFilesAccess: true,
    ), throwsStateError);
  });

  test('mapping must include both locations, never a partial destination', () {
    expect(() => StorageLocationService.validateZipRestoreFileLocations(
      configured: selectedPrimarySAF,
      allFilesAccess: true,
      localEquivalent: {'documentsUri': expectedLocal['documentsUri']!},
    ), throwsStateError);
  });
}
