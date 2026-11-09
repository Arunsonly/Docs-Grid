import 'package:docs_grid/core/storage/storage_location_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('docsgrid/storage');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('only explicit NOT_FOUND errors permit missing-child creation', () {
    expect(StorageLocationService.isNotFoundError(
      PlatformException(code: 'NOT_FOUND'),
    ), isTrue);
    expect(StorageLocationService.isNotFoundError(
      PlatformException(code: 'PERMISSION_DENIED'),
    ), isFalse);
    expect(StorageLocationService.isNotFoundError(StateError('provider unavailable')), isFalse);
  });

  test('savePdf forwards the opaque tree URI, filename and bytes', () async {
    final expectedBytes = Uint8List.fromList([37, 80, 68, 70]);
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'savePdf');
      expect(call.arguments['treeUri'], 'content://tree/root');
      expect(call.arguments['name'], 'policy.pdf');
      expect(call.arguments['bytes'], expectedBytes);
      return 'content://document/policy';
    });

    final result = await StorageLocationService.instance.savePdf(
      treeUri: 'content://tree/root',
      name: 'policy.pdf',
      bytes: expectedBytes,
    );

    expect(result, 'content://document/policy');
  });

  test('copyPdfToPath fails closed when native layer reports false', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => false);

    await expectLater(
      StorageLocationService.instance.copyPdfToPath(
        sourceUri: 'content://document/source',
        destinationPath: '/private/docs/source.pdf',
      ),
      throwsStateError,
    );
  });

  test('findChildUri rejects a null native result', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);

    await expectLater(
      StorageLocationService.instance.findChildUri(
        parentUri: 'content://tree/root',
        name: 'Documents',
      ),
      throwsStateError,
    );
  });

  test('listDirectory rejects incomplete native entries', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => [
      {'name': 'Policy.pdf', 'uri': 'content://document/1'},
    ]);

    await expectLater(
      StorageLocationService.instance.listDirectory('content://tree/root'),
      throwsStateError,
    );
  });

  test('listDirectory preserves opaque URIs and validates valid entries', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => [
      {
        'name': 'Policy.pdf',
        'uri': 'content://document/1',
        'isDirectory': false,
        'sizeBytes': 1024,
      },
    ]);

    final entries = await StorageLocationService.instance.listDirectory(
      'content://tree/root',
    );

    expect(entries, hasLength(1));
    expect(entries.single['uri'], 'content://document/1');
    expect(entries.single['isDirectory'], isFalse);
    expect(entries.single['sizeBytes'], 1024);
  });

  test('createDirectory forwards parent and name and returns opaque URI', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'createDirectory');
      expect(call.arguments, {'parentUri': 'content://tree/root', 'name': 'Invoices'});
      return 'content://document/folder-7';
    });

    expect(
      await StorageLocationService.instance.createDirectory(
        parentUri: 'content://tree/root',
        name: 'Invoices',
      ),
      'content://document/folder-7',
    );
  });

  test('savePdf rejects a null native result', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);

    await expectLater(
      StorageLocationService.instance.savePdf(
        treeUri: 'content://tree/root',
        name: 'empty.pdf',
        bytes: Uint8List(0),
      ),
      throwsStateError,
    );
  });


  test('recursive storage browser includes empty folders and nested PDFs', () async {
    final tree = <String, List<Map<String, Object?>>{
      'content://tree/root': [
        {'name': 'Empty', 'uri': 'content://tree/empty', 'isDirectory': true},
        {'name': 'Insurance', 'uri': 'content://tree/insurance', 'isDirectory': true},
      ],
      'content://tree/empty': [],
      'content://tree/insurance': [
        {'name': 'Policy.pdf', 'uri': 'content://doc/policy', 'isDirectory': false},
        {'name': 'Archive', 'uri': 'content://tree/archive', 'isDirectory': true},
      ],
      'content://tree/archive': [],
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'listDirectory');
      return tree[call.arguments['uri']]!;
    });
    final entries = await StorageLocationService.instance
        .listStorageTreeRecursively('content://tree/root');
    expect(entries.where((entry) => entry['isDirectory'] == true)
        .map((entry) => entry['path']).toSet(),
        {'Empty', 'Insurance', 'Insurance/Archive'});
    expect(entries.where((entry) => entry['isDirectory'] == false).single['uri'],
        'content://doc/policy');
  });

  test('listDirectory rejects a non-map native entry', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => ['not-an-entry']);

    await expectLater(
      StorageLocationService.instance.listDirectory('content://tree/root'),
      throwsStateError,
    );
  });

  test('access status normalization preserves revoked native status', () {
    expect(
      StorageLocationService.normalizeAccessStatus({
        'status': 'revoked',
        'message': 'Permission was removed',
        'name': 'Documents',
      }),
      {
        'status': 'revoked',
        'message': 'Permission was removed',
        'name': 'Documents',
      },
    );
  });

  test('access status normalization fails closed for null native response', () {
    expect(
      StorageLocationService.normalizeAccessStatus(null),
      {
        'status': 'unknown',
        'message': 'Storage access could not be verified.',
      },
    );
  });

  test('native permission errors are propagated instead of treated as missing data', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'PERMISSION_DENIED');
    });

    await expectLater(
      StorageLocationService.instance.readPdf('content://document/private'),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'PERMISSION_DENIED',
        ),
      ),
    );
  });

  test('recursive PDF discovery returns folder paths and keeps provider URIs opaque', () async {
    final tree = <String, List<Map<String, Object?>>>{
      'content://tree/root': [
        {'name': 'Root.pdf', 'uri': 'content://doc/root-pdf', 'isDirectory': false},
        {'name': 'Insurance', 'uri': 'content://tree/insurance', 'isDirectory': true},
        {'name': 'Ignore.txt', 'uri': 'content://doc/text', 'isDirectory': false},
      ],
      'content://tree/insurance': [
        {'name': 'Policy.pdf', 'uri': 'content://doc/policy', 'isDirectory': false},
        {'name': '2026', 'uri': 'content://tree/2026', 'isDirectory': true},
      ],
      'content://tree/2026': [
        {'name': 'Renewal.PDF', 'uri': 'content://doc/renewal', 'isDirectory': false},
        {'name': 'Insurance', 'uri': 'content://tree/insurance', 'isDirectory': true},
      ],
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'listDirectory');
      return tree[call.arguments['uri']]!;
    });

    final files = await StorageLocationService.instance
        .listPdfFilesRecursively('content://tree/root');

    expect(files.map((file) => file['name']).toList(),
        ['Root.pdf', 'Policy.pdf', 'Renewal.PDF']);
    expect(files[1]['folderPath'], 'Insurance');
    expect(files[2]['folderPath'], 'Insurance/2026');
    expect(files[2]['uri'], 'content://doc/renewal');
  });

  test('recursive PDF discovery stops safely at configured entry limit', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => [
      {'name': 'A.pdf', 'uri': 'content://doc/a', 'isDirectory': false},
      {'name': 'B.pdf', 'uri': 'content://doc/b', 'isDirectory': false},
    ]);

    await expectLater(
      StorageLocationService.instance.listPdfFilesRecursively(
        'content://tree/root',
        maxEntries: 1,
      ),
      throwsStateError,
    );
  });

}
