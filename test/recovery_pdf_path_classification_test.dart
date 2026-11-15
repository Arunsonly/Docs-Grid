import 'package:docs_grid/core/storage/storage_location_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('docsgrid/storage');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Recovery treats RAS .pdf as a file, never as its own parent folder', () async {
    const fileName = 'RAS_Political_Science_Current_Affairs_2025_26_.pdf';
    final requested = <String>[];

    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'listDirectory');
      final uri = (call.arguments as Map)['uri'] as String;
      requested.add(uri);
      switch (uri) {
        case 'content://grid-library':
          return <Map<String, Object?>>[
            {'name': 'RAS', 'uri': 'content://grid-ras', 'isDirectory': true},
          ];
        case 'content://grid-ras':
          return <Map<String, Object?>>[
            {'name': fileName, 'uri': 'content://ras-pdf', 'isDirectory': false, 'size': 1200},
          ];
        default:
          throw StateError('Scanner tried to enter a PDF as if it were a folder: $uri');
      }
    });

    final entries = await StorageLocationService.instance
        .listPdfFilesRecursively('content://grid-library');

    expect(entries, hasLength(1));
    expect(entries.single['name'], fileName);
    expect(entries.single['folderPath'], 'RAS');
    expect(entries.single['uri'], 'content://ras-pdf');
    expect(requested, ['content://grid-library', 'content://grid-ras']);
  });

  test('Recovery PDF directly at Grid root has no parent folder to reconstruct', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => <Map<String, Object?>>[
      {
        'name': 'RAS_Political_Science_Current_Affairs_2025_26_.pdf',
        'uri': 'content://root-pdf',
        'isDirectory': false,
        'size': 100,
      },
    ]);
    final entries = await StorageLocationService.instance
        .listPdfFilesRecursively('content://grid-library');
    expect(entries, hasLength(1));
    expect(entries.single['folderPath'], isEmpty);
    expect(entries.single['name'], endsWith('.pdf'));
  });
}
