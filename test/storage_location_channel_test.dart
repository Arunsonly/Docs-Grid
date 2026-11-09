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
}
