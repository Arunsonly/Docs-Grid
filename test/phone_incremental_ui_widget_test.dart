import 'package:docs_grid/features/documents/presentation/document_thumbnail.dart';
import 'package:docs_grid/features/documents/presentation/phone_storage_browser_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Map<String, Object?> pdf(String uri, String name) => {
    'name': name,
    'uri': uri,
    'folderPath': 'Internal/Download',
    'isDirectory': false,
    'sizeBytes': 10,
    'lastModified': 1700000000000,
  };

  testWidgets('Phone receives incremental records without closing opened folder',
      (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final old = pdf('content://media/external_primary/file/1', 'Old.pdf');
    final added = pdf('content://media/external_primary/file/2', 'Added.pdf');
    Future<void> render(List<Map<String, Object?>> entries) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: PhoneStorageBrowserScreen(
              key: const ValueKey('stable-phone-browser'),
              embedded: true,
              rootName: 'Internal Storage',
              entries: entries,
              onOpenPdf: (_, __) async {},
            ),
          ),
        ));

    await render([old]);
    await tester.tap(find.byKey(const ValueKey('phone-folder-Download')));
    await tester.pumpAndSettle();
    expect(find.text('Old.pdf'), findsOneWidget);

    // The parent updates only one metadata row and keeps the widget identity.
    await render([old, added]);
    await tester.pumpAndSettle();
    expect(find.text('Old.pdf'), findsOneWidget);
    expect(find.text('Added.pdf'), findsOneWidget);
    expect(find.text('2 PDFs'), findsOneWidget);
    expect(find.byTooltip('Back to folders'), findsOneWidget);

    // Removing a single row does not navigate away or clear other documents.
    await render([added]);
    await tester.pumpAndSettle();
    expect(find.text('Old.pdf'), findsNothing);
    expect(find.text('Added.pdf'), findsOneWidget);
    expect(find.text('1 PDFs'), findsOneWidget);
    expect(find.byTooltip('Back to folders'), findsOneWidget);
  });

  testWidgets('Phone creates only visible PDF widgets in a large folder',
      (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PhoneStorageBrowserScreen(
          embedded: true,
          rootName: 'Internal Storage',
          entries: [
            for (var i = 0; i < 250; i++)
              pdf('content://media/external_primary/file/$i', 'Item_$i.pdf'),
          ],
          onOpenPdf: (_, __) async {},
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('phone-folder-Download')));
    await tester.pumpAndSettle();
    expect(find.byType(DocumentThumbnail).evaluate().length,
        lessThan(250));
    expect(find.text('250 PDFs'), findsOneWidget);
  });
}
