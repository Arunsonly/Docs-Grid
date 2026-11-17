import 'package:docs_grid/features/documents/data/phone_trash_origin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Primary MediaStore stores the granted root, not an expired PDF URI', () {
    final roots = [
      {'uri': 'file:///storage/emulated/0', 'name': 'Internal storage'},
      {'uri': 'file:///storage/1234-5678', 'name': 'External storage 1'},
    ];
    const source = 'content://media/external_primary/file/700';
    expect(PhoneTrashOrigin.selectGrantedRoot(
      sourceUri: source, folderPath: 'Internal/Download/Policy',
      volumeName: 'external_primary', roots: roots,
    ), roots.first['uri']);
    final original = PhoneTrashOrigin(
      sourceUri: source,
      folderPath: 'Internal/Download/Policy',
      rootUri: roots.first['uri']!,
      volumeName: 'external_primary',
      displayName: 'Insurance.pdf',
    );
    expect(original.relativeFolders, ['Download', 'Policy']);
    expect(PhoneTrashOrigin.fromMetadata({
      PhoneTrashOrigin.metadataKey: original.toJson(),
    })?.toJson(), original.toJson());
  });

  test('Removable SD card is identified by volume ID, not scanner index', () {
    final roots = [
      {'uri': 'file:///storage/emulated/0', 'name': 'Internal storage'},
      {'uri': 'file:///storage/AB12-CD34', 'name': 'External storage 1'},
    ];
    expect(PhoneTrashOrigin.selectGrantedRoot(
      sourceUri: 'content://media/AB12-CD34/file/77',
      folderPath: 'External storage 0/PDFs',
      roots: roots, volumeName: 'AB12-CD34',
    ), 'file:///storage/AB12-CD34');
    expect(PhoneTrashOrigin.selectGrantedRoot(
      sourceUri: 'content://media/AB12-CD34/file/77',
      folderPath: 'External storage 0/PDFs',
      roots: roots.take(1), volumeName: 'AB12-CD34',
    ), isNull, reason: 'Unmounted SD must not restore into Internal storage.');
  });

  test('SAF restores only under same provider and original granted tree', () {
    const source = 'content://com.android.externalstorage.documents/tree/primary%3ADocuments/document/primary%3ADocuments%2FA%2Ffile.pdf';
    const granted = 'content://com.android.externalstorage.documents/tree/primary%3ADocuments';
    expect(PhoneTrashOrigin.selectGrantedRoot(
      sourceUri: source,
      folderPath: 'Granted folder 1/A', roots: [
        {'uri': granted, 'name': 'Granted folder 1'},
        {'uri': 'content://evil.provider/tree/primary%3ADocuments',
         'name': 'Granted folder 2'},
      ],
    ), granted);
    expect(PhoneTrashOrigin.selectGrantedRoot(
      sourceUri: source,
      folderPath: 'Granted folder 1/A', roots: [
        {'uri': 'content://evil.provider/tree/primary%3ADocuments',
         'name': 'Granted folder 1'},
      ],
    ), isNull);
  });

  test('file URI must belong inside explicitly approved shared root', () {
    expect(PhoneTrashOrigin.selectGrantedRoot(
      sourceUri: 'file:///storage/emulated/0/Download/A.pdf',
      folderPath: 'Internal/Download', roots: [
        {'uri': 'file:///storage/emulated/0', 'name': 'Internal storage'},
      ],
    ), 'file:///storage/emulated/0');
    expect(PhoneTrashOrigin.selectGrantedRoot(
      sourceUri: 'file:///data/user/0/private.pdf',
      folderPath: 'Internal/Download', roots: [
        {'uri': 'file:///storage/emulated/0', 'name': 'Internal storage'},
      ],
    ), isNull);
  });

  test('folder path validation rejects dot segments and missing labels', () {
    PhoneTrashOrigin origin(String folder) => PhoneTrashOrigin(
      sourceUri: 'content://media/external_primary/file/4',
      folderPath: folder, rootUri: 'file:///storage/emulated/0',
      displayName: 'Policy.pdf', volumeName: 'external_primary',
    );
    expect(origin('Internal').relativeFolders, isEmpty);
    expect(origin('Internal/Docs/PDF').relativeFolders, ['Docs', 'PDF']);
    expect(() => origin('Internal/../Grid').relativeFolders, throwsStateError);
    expect(() => origin('Internal//PDF').relativeFolders, throwsStateError);
    expect(() => origin('Download').relativeFolders, throwsStateError);
    expect(PhoneTrashOrigin.fromMetadata({'phoneTrashOrigin': {
      'sourceUri': '', 'folderPath': 'Internal/A',
      'rootUri': 'file:///storage/emulated/0',
      'displayName': 'A.pdf',
    }}), isNull);
  });

  test('local source and saved label must describe same physical parent', () {
    PhoneTrashOrigin origin(String folder) => PhoneTrashOrigin(
      sourceUri: 'file:///storage/emulated/0/Download/Policy.pdf',
      folderPath: folder,
      rootUri: 'file:///storage/emulated/0',
      displayName: 'Policy.pdf',
    );
    expect(origin('Internal/Download').localSourceMatchesRoot(), isTrue);
    expect(origin('Internal/Other').localSourceMatchesRoot(), isFalse);
    expect(origin('Internal/../Other').localSourceMatchesRoot(), throwsStateError);
  });
}
