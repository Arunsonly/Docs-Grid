import 'package:docs_grid/core/storage/grid_storage_boundary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android root-level DocsGrid excluded; other Documents PDFs retained', () {
    final boundary = GridStorageBoundary(
        activeRootUri: 'file:///storage/emulated/0/DocsGrid');
    final entries = <Map<String, Object?>>[
      {'name': 'Policy.pdf', 'uri': 'content://media/external_primary/file/1',
       'folderPath': 'Internal/DocsGrid/My Files/Unfiled',
       'volumeName': 'external_primary'},
      {'name': 'Grid', 'path': 'Internal/DocsGrid', 'isDirectory': true},
      {'name': 'Personal.pdf', 'folderPath': 'Internal/Documents',
       'uri': 'content://media/external_primary/file/2',
       'volumeName': 'external_primary'},
      {'name': 'Other.pdf', 'folderPath': 'Internal/BackupDocsGrid',
       'volumeName': 'external_primary'},
    ];
    expect(boundary.filterEntries(entries).map((e) => e['name']).toList(),
        ['Personal.pdf', 'Other.pdf']);
    expect(boundary.isManagedPath('Internal/DocsGrid/Folders',
        volumeName: 'sd_card'), isFalse,
        reason: 'Identically named SD-card folders are unrelated');
    expect(boundary.isManagedPath('DocsGrid/Folders',
        scanRootUri: 'file:///storage/1234-5678',
        rootLabel: 'SD Card'), isFalse,
        reason: 'Recursive scan of a separate SD card must keep its own PDFs');
  });

  test('custom Android storage location under Documents excludes only that subtree', () {
    final boundary = GridStorageBoundary(
      activeRootUri: 'file:///storage/emulated/0/Documents/MyDocsGrid',
    );
    expect(boundary.isManagedPath('Internal/Documents/MyDocsGrid/Invoices',
        volumeName: 'external_primary'), isTrue);
    expect(boundary.isManagedPath('Internal/Documents/AnotherGrid/Invoices',
        volumeName: 'external_primary'), isFalse);
    expect(boundary.isManagedPath('Internal/Download/MyDocsGrid/Invoices',
        volumeName: 'external_primary'), isFalse);
  });

  test('Android SAF primary root is resolved without assuming MediaStore URI names', () {
    final boundary = GridStorageBoundary(
      activeRootUri:
          'content://com.android.externalstorage.documents/tree/primary%3ADocuments%2FMyDocsGrid',
    );
    expect(boundary.isManagedPath('Internal/Documents/MyDocsGrid/Folder',
        volumeName: 'external_primary'), isTrue);
    expect(boundary.isManagedPath('Internal/Documents/Unrelated',
        volumeName: 'external_primary'), isFalse);
  });

  test('iOS selected Files parent excludes its Grid child but not peer folders', () {
    const parent = 'file:///private/var/mobile/Containers/Shared/AppGroup/MyFolder';
    final boundary = GridStorageBoundary(activeRootUri: '$parent/DocsGrid');
    final entries = <Map<String, Object?>>[
      {'name': 'Grid', 'isDirectory': true, 'path': 'MyFolder/DocsGrid',
       'folderPath': 'MyFolder'},
      {'name': 'Normal.pdf', 'folderPath': 'MyFolder/Other',
       'uri': '$parent/Other/Normal.pdf'},
      {'name': 'Mine.pdf', 'folderPath': 'MyFolder/DocsGrid/Documents',
       'uri': '$parent/DocsGrid/Documents/Mine.pdf'},
    ];
    expect(boundary.filterEntries(entries,
        scanRootUri: parent, rootLabel: 'MyFolder')
        .map((e) => e['name']).toList(), ['Normal.pdf']);
  });

  test('old Android/media Grid remains excluded after new root selected', () {
    final boundary = GridStorageBoundary(
        activeRootUri: 'file:///storage/emulated/0/DocsGrid');
    expect(boundary.isManagedPath(
        'Internal/Android/media/com.docsgrid.mobile/My Files/Folders'),
        isTrue);
    expect(boundary.isManagedPath(
        'Internal/Android/media/com.docsgrid/My Files/Folders'),
        isTrue);
    expect(boundary.isManagedPath(
        'Internal/Android/media/com.whatsapp/WhatsApp Documents'), isFalse);
  });

  test('a Phone browse root matching Grid root shows no managed PDFs', () {
    const grid = 'file:///storage/emulated/0/DocsGrid';
    final boundary = GridStorageBoundary(activeRootUri: grid);
    expect(boundary.isManagedPath('', scanRootUri: grid), isTrue);
    expect(boundary.isManagedEntry({'name': 'Grid.pdf', 'folderPath': ''},
        scanRootUri: grid), isTrue);
  });
}
