import 'package:docs_grid/features/documents/presentation/phone_storage_browser_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Phone search uses filenames and does not expose OCR',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PhoneStorageBrowserScreen(
        embedded: true,
        rootName: 'Internal Storage',
        entries: const [
          {
            'name': 'Invoice.pdf',
            'uri': 'content://phone/invoice',
            'path': 'Internal/Download',
            'folderPath': 'Internal/Download',
            'isDirectory': false,
            'sizeBytes': 123,
          },
          {
            'name': 'Other.pdf',
            'uri': 'content://phone/other',
            'path': 'Internal/Download',
            'folderPath': 'Internal/Download',
            'isDirectory': false,
            'sizeBytes': 50,
          },
        ],
        onOpenPdf: (_, __) async {},
      )),
    ));
    await tester.enterText(find.byType(TextField).first, '982731');
    await tester.pumpAndSettle();
    expect(find.text('Invoice.pdf'), findsNothing);
    expect(find.byKey(const ValueKey('ocr-search-mode-selector')), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'Invoice');
    await tester.pumpAndSettle();
    expect(find.text('Invoice.pdf'), findsOneWidget);
    expect(find.text('Other.pdf'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Phone OCR toggle is absent without Settings permission',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PhoneStorageBrowserScreen(
        rootName: 'Internal Storage',
        embedded: true,
        entries: const [],
        onOpenPdf: (_, __) async {},
      )),
    ));
    expect(find.byKey(const ValueKey('ocr-search-mode-selector')), findsNothing);
  });
}
