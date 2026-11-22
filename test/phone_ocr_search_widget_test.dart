import 'package:docs_grid/features/documents/presentation/phone_storage_browser_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Phone search stays name-only until OCR is tapped; content then matches',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var extracted = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PhoneStorageBrowserScreen(
        embedded: true,
        rootName: 'Internal Storage',
        ocrSearchAvailable: true,
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
        ocrTextExtractor: (uri, {shouldCancel}) async {
          extracted++;
          return uri.endsWith('invoice')
              ? 'Insurance reference 982731'
              : 'Unrelated photograph';
        },
        onOpenPdf: (_, __) async {},
      )),
    ));
    await tester.enterText(find.byType(TextField).first, '982731');
    await tester.pumpAndSettle();
    expect(extracted, 0);
    expect(find.text('Invoice.pdf'), findsNothing);
    expect(find.byTooltip('Turn on OCR search'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ocr-search-mode-selector')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(extracted, 2);
    expect(find.text('Invoice.pdf'), findsOneWidget);
    expect(find.text('Other.pdf'), findsNothing);
    expect(find.byTooltip('Turn off OCR search'), findsOneWidget);
    expect(find.byType(PopupMenuButton<bool>), findsNothing);

    await tester.tap(find.byKey(const ValueKey('ocr-search-mode-selector')));
    await tester.pumpAndSettle();
    expect(find.text('Invoice.pdf'), findsNothing,
        reason: 'Returning to filename search must ignore PDF contents.');
    expect(find.byTooltip('Turn on OCR search'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Invoice');
    await tester.pumpAndSettle();
    expect(find.text('Invoice.pdf'), findsOneWidget);
    expect(extracted, 2, reason: 'Ordinary name search must not invoke OCR.');
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
