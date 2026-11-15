import 'dart:async';

import 'package:docs_grid/core/storage/phone_storage_scan_cache.dart';
import 'package:docs_grid/features/documents/presentation/phone_storage_browser_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phone tab embeds the browser instead of showing an Open button',
      (tester) async {
    final stream = StreamController<Map<String, Object?>>();
    final cache = PhoneStorageScanCache(
      loadRoots: () async => const [{'uri': 'content://root', 'name': 'Phone'}],
      scanRoot: (_) => stream.stream,
    );
    final pending = cache.scan();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('DocsGrid')),
        body: PhoneStorageBrowserScreen(
          rootName: 'Internal Storage',
          entries: const [],
          scanCache: cache,
          embedded: true,
          onOpenPdf: (_, __) async {},
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('Open Phone storage'), findsNothing);
    expect(find.textContaining('Scanning'), findsWidgets);

    stream.add({
      'name': 'Policy.pdf',
      'uri': 'content://policy',
      'folderPath': 'Documents',
      'sizeBytes': 100,
      'isDirectory': false,
    });
    await stream.close();
    await pending;
    await tester.pump();
    expect(find.text('Documents'), findsOneWidget);
    expect(find.text('Open Phone storage'), findsNothing);
    cache.dispose();
  });
}
