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

  const actionEntries = <Map<String, Object?>>[
    {
      'name': 'Policy.pdf',
      'uri': 'content://document/policy',
      'folderPath': '',
      'isDirectory': false,
      'sizeBytes': 128,
    },
  ];

  Future<void> openActionBrowser(
    WidgetTester tester, {
    Future<bool> Function(String, String)? onMove,
    Future<bool> Function(String, String)? onRename,
    Future<bool> Function(String, String)? onTrash,
    Future<void> Function(String, String)? onShare,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => PhoneStorageBrowserScreen(
                  rootName: 'Phone Storage',
                  entries: actionEntries,
                  onOpenPdf: (_, __) async {},
                  onMovePdf: onMove,
                  onRenamePdf: onRename,
                  onSharePdf: onShare,
                  onTrashPdf: onTrash,
                ),
              ),
            ),
            child: const Text('Open browser'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open browser'));
    await tester.pumpAndSettle();
    expect(find.text('Phone Storage'), findsOneWidget);
    expect(find.text('Policy.pdf'), findsOneWidget);
  }

  Future<void> selectAction(WidgetTester tester, String action) async {
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action).last);
    await tester.pumpAndSettle();
  }

  testWidgets('successful Move closes the stale Phone Storage snapshot', (tester) async {
    await openActionBrowser(tester, onMove: (_, __) async => true);
    await selectAction(tester, 'Move to Grid');
    expect(find.text('Open browser'), findsOneWidget);
    expect(find.text('Phone Storage'), findsNothing);
  });

  testWidgets('duplicate Move keeps the Phone Storage browser open', (tester) async {
    await openActionBrowser(tester, onMove: (_, __) async => false);
    await selectAction(tester, 'Move to Grid');
    expect(find.text('Phone Storage'), findsOneWidget);
    expect(find.text('Policy.pdf'), findsOneWidget);
  });

  testWidgets('successful Rename closes the stale Phone Storage snapshot', (tester) async {
    await openActionBrowser(tester, onRename: (_, __) async => true);
    await selectAction(tester, 'Rename');
    expect(find.text('Open browser'), findsOneWidget);
    expect(find.text('Phone Storage'), findsNothing);
  });

  testWidgets('failed Rename keeps the Phone Storage browser open', (tester) async {
    await openActionBrowser(tester, onRename: (_, __) async => false);
    await selectAction(tester, 'Rename');
    expect(find.text('Phone Storage'), findsOneWidget);
    expect(find.text('Policy.pdf'), findsOneWidget);
  });

  testWidgets('successful Recycle Bin move closes the stale browser', (tester) async {
    await openActionBrowser(tester, onTrash: (_, __) async => true);
    await selectAction(tester, 'Move to Recycle Bin');
    expect(find.text('Open browser'), findsOneWidget);
    expect(find.text('Phone Storage'), findsNothing);
  });

  testWidgets('Share does not close the Phone Storage browser', (tester) async {
    await openActionBrowser(tester, onShare: (_, __) async {});
    await selectAction(tester, 'Share');
    expect(find.text('Phone Storage'), findsOneWidget);
    expect(find.text('Policy.pdf'), findsOneWidget);
  });

}
