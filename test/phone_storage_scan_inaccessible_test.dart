import 'package:docs_grid/core/storage/storage_location_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('docsgrid/storage');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Phone scan reports unreadable folders without hiding accessible PDFs', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'listDirectory') throw StateError('Unexpected storage action');
      final uri = call.arguments['uri'] as String;
      if (uri == 'content://root') return [
        {'name': 'Protected', 'uri': 'content://protected', 'isDirectory': true},
        {'name': 'Documents', 'uri': 'content://documents', 'isDirectory': true},
      ];
      if (uri == 'content://protected') {
        throw PlatformException(code: 'PERMISSION_DENIED', message: 'Protected folder');
      }
      if (uri == 'content://documents') return [
        {'name': 'Policy.pdf', 'uri': 'content://policy', 'isDirectory': false, 'sizeBytes': 80},
      ];
      return <Map<String, Object?>>[];
    });

    final entries = await StorageLocationService.instance
        .streamPdfFiles('content://root').toList();

    expect(entries.where((entry) => entry['name'] == 'Policy.pdf'), hasLength(1));
    expect(entries.where((entry) => entry['isInaccessible'] == true), hasLength(1));
    expect(entries.singleWhere((entry) => entry['isInaccessible'] == true)['uri'],
        'content://protected');
  });
}
