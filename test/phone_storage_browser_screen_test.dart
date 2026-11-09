import 'package:docs_grid/features/documents/presentation/phone_storage_browser_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('phone browser navigates only PDF-bearing folders and opens PDFs',
      (tester) async {
    String? openedUri;
    String? openedName;
    final entries = <Map<String, Object?>>[
      {'name': 'Insurance', 'uri': '', 'folderPath': '', 'path': 'Insurance', 'isDirectory': true},
      {'name': 'Archive', 'uri': '', 'folderPath': 'Insurance', 'path': 'Insurance/Archive', 'isDirectory': true},
      {'name': 'Policy.pdf', 'uri': 'content://policy', 'folderPath': 'Insurance/Archive', 'isDirectory': false},
      {'name': 'Root.pdf', 'uri': 'content://root', 'folderPath': '', 'isDirectory': false},
    ];

    await tester.pumpWidget(MaterialApp(
      home: PhoneStorageBrowserScreen(
        rootName: 'Documents',
        entries: entries,
        onOpenPdf: (uri, name) async {
          openedUri = uri;
          openedName = name;
        },
      ),
    ));

    expect(find.text('Insurance'), findsOneWidget);
    expect(find.text('Root.pdf'), findsOneWidget);
    expect(find.text('Archive'), findsNothing);

    await tester.tap(find.text('Insurance'));
    await tester.pumpAndSettle();
    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Policy.pdf'), findsNothing);

    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(find.text('Policy.pdf'), findsOneWidget);
    await tester.tap(find.text('Policy.pdf'));
    await tester.pumpAndSettle();

    expect(openedUri, 'content://policy');
    expect(openedName, 'Policy.pdf');

    // System Back first navigates to the parent folder, then to the root.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Policy.pdf'), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Insurance'), findsOneWidget);
    expect(find.text('Root.pdf'), findsOneWidget);
  });
}
