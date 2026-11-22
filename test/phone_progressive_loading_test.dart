import 'package:docs_grid/features/documents/presentation/document_thumbnail.dart';
import 'package:docs_grid/features/documents/presentation/phone_storage_browser_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  void viewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  List<Map<String, Object?>> documents(int count) => [
    for (var i = 0; i < count; i++)
      <String, Object?>{
        'name': 'Policy_${i.toString().padLeft(3, '0')}.pdf',
        'uri': 'content://media/external_primary/file/$i',
        'folderPath': 'Internal/Insurance',
        'sizeBytes': 1024,
        'lastModified': 1800000000000 + i,
        'isDirectory': false,
      },
  ];

  testWidgets('Phone initially shows a limited rendered page but retains true folder count',
      (tester) async {
    viewport(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PhoneStorageBrowserScreen(
        embedded: true, rootName: 'Internal Storage',
        entries: documents(175),
        onOpenPdf: (_, __) async {},
      )),
    ));
    await tester.tap(find.byKey(const ValueKey('phone-folder-Insurance')));
    await tester.pumpAndSettle();
    expect(find.text('175 PDFs'), findsOneWidget);
    expect(find.text('Policy_000.pdf'), findsOneWidget);
    expect(find.text('Policy_174.pdf'), findsNothing);
    // ListView.builder renders only the viewport, never every thumbnail.
    expect(find.byType(DocumentThumbnail).evaluate().length, lessThan(60));

    final list = find.byType(ListView).last;
    await tester.scrollUntilVisible(
      find.text('Policy_085.pdf'), 460,
      scrollable: find.descendant(
        of: list, matching: find.byType(Scrollable),
      ).first,
      maxScrolls: 25,
    );
    await tester.pumpAndSettle();
    expect(find.text('Policy_085.pdf'), findsOneWidget);
    expect(find.text('175 PDFs'), findsOneWidget);
  });

  testWidgets('Phone progressive page resets correctly when changing folders',
      (tester) async {
    viewport(tester);
    final entries = [
      ...documents(135),
      ...[
        for (var i = 0; i < 3; i++)
          <String, Object?>{
            'name': 'Other_$i.pdf',
            'uri': 'content://media/external_primary/file/other_$i',
            'folderPath': 'Internal/Other',
            'sizeBytes': 2048,
            'isDirectory': false,
          },
      ],
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PhoneStorageBrowserScreen(
        embedded: true, rootName: 'Internal Storage',
        entries: entries, onOpenPdf: (_, __) async {},
      )),
    ));
    await tester.tap(find.byKey(const ValueKey('phone-folder-Insurance')));
    await tester.pumpAndSettle();
    expect(find.text('135 PDFs'), findsOneWidget);
    await tester.tap(find.byTooltip('Back to folders'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('phone-folder-Other')));
    await tester.pumpAndSettle();
    expect(find.text('3 PDFs'), findsOneWidget);
    expect(find.text('Other_0.pdf'), findsOneWidget);
    expect(find.text('Policy_000.pdf'), findsNothing);
  });
}
