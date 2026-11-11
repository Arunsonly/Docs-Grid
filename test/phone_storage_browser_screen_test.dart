import 'package:docs_grid/features/documents/presentation/phone_storage_browser_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  void setTestViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding.zero;
    tester.view.viewPadding = FakeViewPadding.zero;
    tester.view.viewInsets = FakeViewPadding.zero;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  
    testWidgets('lists only folders with direct PDFs and opens that folder PDFs',
      (tester) async {
    setTestViewport(tester);
    String? openedUri;
    String? openedName;
    final entries = <Map<String, Object?>>[
      {'name': 'Work Files', 'uri': '', 'folderPath': '', 'path': 'Work Files', 'isDirectory': true},
      {'name': 'Archived Files', 'uri': '', 'folderPath': 'Work Files', 'path': 'Work Files/Archived Files', 'isDirectory': true},
      {'name': 'Empty Folder', 'uri': '', 'folderPath': '', 'path': 'Empty Folder', 'isDirectory': true},
      {'name': 'Policy.pdf', 'uri': 'content://policy', 'folderPath': '', 'path': 'Work Files', 'isDirectory': false, 'sizeBytes': 128},
      {'name': 'Archived Filesd.pdf', 'uri': 'content://archive', 'folderPath': '', 'path': 'Work Files/Archived Files', 'isDirectory': false, 'sizeBytes': 256},
      {'name': 'Root.pdf', 'uri': 'content://root', 'folderPath': '', 'path': '', 'isDirectory': false},
    ];

    await tester.pumpWidget(MaterialApp(
      home: PhoneStorageBrowserScreen(
        rootName: 'Internal Storage',
        entries: entries,
        onOpenPdf: (uri, name) async {
          openedUri = uri;
          openedName = name;
        },
      ),
    ));

    expect(find.text('Work Files'), findsOneWidget);
    expect(find.text('Archived Files'), findsOneWidget);
    expect(find.text('Empty Folder'), findsNothing);
    expect(find.text('Policy.pdf'), findsNothing);
    expect(find.text('Root.pdf'), findsNothing);
    expect(find.text('Internal'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('phone-folder-Work Files')));
    await tester.pumpAndSettle();
    expect(find.text('Policy.pdf'), findsOneWidget);
    expect(find.text('Archived Filesd.pdf'), findsNothing);

    await tester.tap(find.text('Policy.pdf'));
    await tester.pumpAndSettle();
    expect(openedUri, 'content://policy');
    expect(openedName, 'Policy.pdf');

    await tester.tap(find.byTooltip('Back to folders'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('phone-folder-Internal')));
    await tester.pumpAndSettle();
    expect(find.text('Root.pdf'), findsOneWidget);
    await tester.tap(find.text('Root.pdf'));
    await tester.pumpAndSettle();
    expect(openedUri, 'content://root');
  });

  testWidgets('opened folder shows its own PDF count, modified date and size', (tester) async {
    setTestViewport(tester);
    final modifiedAt = DateTime(2026, 11, 11, 19, 26).millisecondsSinceEpoch;
    await tester.pumpWidget(MaterialApp(
      home: PhoneStorageBrowserScreen(
        rootName: 'Internal Storage',
        entries: [
          {
            'name': 'Download',
            'uri': '',
            'folderPath': 'Internal',
            'path': 'Internal/Download',
            'isDirectory': true,
            'pdfCount': 1,
            'sizeBytes': 126976,
          },
          {
            'name': 'Policy.pdf',
            'uri': 'content://download/policy',
            'folderPath': 'Internal/Download',
            'path': 'Internal/Download',
            'isDirectory': false,
            'sizeBytes': 126976,
            'lastModified': modifiedAt,
          },
        ],
        onOpenPdf: (_, __) async {},
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('phone-folder-Download')));
    await tester.pumpAndSettle();
    expect(find.text('Policy.pdf'), findsOneWidget);
    expect(find.text('1 PDFs'), findsOneWidget);
    expect(find.textContaining('11-Nov-2026 19:26'), findsOneWidget);
    expect(find.textContaining('124.0 KB'), findsOneWidget);
  });

  testWidgets('search finds PDFs across phone folders from the root view',
      (tester) async {
    setTestViewport(tester);
    await tester.pumpWidget(MaterialApp(
      home: PhoneStorageBrowserScreen(
        rootName: 'Internal Storage',
        entries: const [
          {
            'name': 'Policy-2026.pdf',
            'uri': 'content://policy-2026',
            'folderPath': 'Internal/Insurance',
            'path': 'Internal/Insurance',
            'isDirectory': false,
          },
          {
            'name': 'Vehicle-Quote.pdf',
            'uri': 'content://vehicle',
            'folderPath': 'Internal/Motor',
            'path': 'Internal/Motor',
            'isDirectory': false,
          },
          {
            'name': 'Insurance',
            'uri': '',
            'folderPath': 'Internal',
            'path': 'Internal/Insurance',
            'isDirectory': true,
            'pdfCount': 1,
          },
        ],
        onOpenPdf: (_, __) async {},
      ),
    ));

    await tester.enterText(
      find.byType(TextField),
      'Policy-2026',
    );
    await tester.pumpAndSettle();
    expect(find.text('Policy-2026.pdf'), findsOneWidget);
    expect(find.text('Vehicle-Quote.pdf'), findsNothing);
  });

  testWidgets('does not show a parent folder when PDFs exist only in a nested folder',
      (tester) async {
    setTestViewport(tester);
    await tester.pumpWidget(MaterialApp(
      home: PhoneStorageBrowserScreen(
        rootName: 'Internal Storage',
        entries: const [
          {
            'name': 'Android',
            'uri': '',
            'folderPath': 'Internal',
            'path': 'Internal/Android',
            'isDirectory': true,
            'pdfCount': 0,
          },
          {
            'name': 'data',
            'uri': '',
            'folderPath': 'Internal/Android',
            'path': 'Internal/Android/data',
            'isDirectory': true,
            'pdfCount': 1,
          },
          {
            'name': 'Nested.pdf',
            'uri': 'content://nested',
            'folderPath': 'Internal/Android/data',
            'path': 'Internal/Android/data',
            'isDirectory': false,
          },
        ],
        onOpenPdf: (_, __) async {},
      ),
    ));
    expect(find.text('Android'), findsNothing);
    expect(find.text('data'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('phone-folder-Android/data')));
    await tester.pumpAndSettle();
    expect(find.text('Nested.pdf'), findsOneWidget);
  });

  testWidgets('embedded Phone browser stays in place and returns to folder list',
      (tester) async {
    setTestViewport(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PhoneStorageBrowserScreen(
        rootName: 'Internal Storage',
        embedded: true,
        entries: const [
          {
            'name': 'Policies',
            'uri': '',
            'folderPath': 'Internal',
            'path': 'Internal/Policies',
            'isDirectory': true,
            'pdfCount': 1,
          },
          {
            'name': 'Policy.pdf',
            'uri': 'content://policy',
            'folderPath': 'Internal/Policies',
            'path': 'Internal/Policies',
            'isDirectory': false,
          },
        ],
        onOpenPdf: (_, __) async {},
        ),
      ),
    ));

    await tester.tap(find.byKey(const ValueKey('phone-folder-Policies')));
    await tester.pumpAndSettle();
    expect(find.text('Policy.pdf'), findsOneWidget);
    await tester.tap(find.byTooltip('Back to folders'));
    await tester.pumpAndSettle();
    expect(find.text('Policies'), findsOneWidget);
  });

  testWidgets('system back returns to Phone folder list before leaving tab',
      (tester) async {
    setTestViewport(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PhoneStorageBrowserScreen(
          rootName: 'Internal Storage',
          embedded: true,
          entries: const [
            {
              'name': 'Policies',
              'uri': '',
              'folderPath': 'Internal',
              'path': 'Internal/Policies',
              'isDirectory': true,
              'pdfCount': 1,
            },
            {
              'name': 'Policy.pdf',
              'uri': 'content://policy',
              'folderPath': 'Internal/Policies',
              'path': 'Internal/Policies',
              'isDirectory': false,
            },
          ],
          onOpenPdf: (_, __) async {},
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('phone-folder-Policies')));
    await tester.pumpAndSettle();
    expect(find.text('Policy.pdf'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Policies'), findsOneWidget);
    expect(find.text('Policy.pdf'), findsNothing);
  });

  testWidgets('folder menu shows folder name and full path above its action',
      (tester) async {
    setTestViewport(tester);
    await tester.pumpWidget(MaterialApp(
      home: PhoneStorageBrowserScreen(
        rootName: 'Internal Storage',
        entries: const [
          {'name': 'Policy.pdf', 'uri': 'content://policy', 'folderPath': '', 'path': 'Documents/Work Files', 'isDirectory': false},
        ],
        onOpenPdf: (_, __) async {},
      ),
    ));

    await tester.tap(find.byTooltip('Folder details and actions'));
    await tester.pumpAndSettle();
    expect(find.text('Work Files'), findsNWidgets(2));
    expect(find.text('Internal Storage/Documents/Work Files'), findsOneWidget);
    expect(find.text('Open folder'), findsOneWidget);
  });

  const actionEntries = <Map<String, Object?>>[
    {
      'name': 'Policy.pdf',
      'uri': 'content://document/policy',
      'folderPath': '',
      'path': 'Personal Documents',
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
    setTestViewport(tester);
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

    expect(find.text('Personal Documents'), findsOneWidget);
    await tester.tap(find.text('Personal Documents'));
    await tester.pumpAndSettle();
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

  testWidgets('duplicate Move keeps the selected folder browser open', (tester) async {
    await openActionBrowser(tester, onMove: (_, __) async => false);
    await selectAction(tester, 'Move to Grid');
    expect(find.text('Personal Documents'), findsOneWidget);
    expect(find.text('Policy.pdf'), findsOneWidget);
  });

  testWidgets('successful Rename closes the stale Phone Storage snapshot', (tester) async {
    await openActionBrowser(tester, onRename: (_, __) async => true);
    await selectAction(tester, 'Rename');
    expect(find.text('Open browser'), findsOneWidget);
    expect(find.text('Phone Storage'), findsNothing);
  });

  testWidgets('failed Rename keeps the selected folder browser open', (tester) async {
    await openActionBrowser(tester, onRename: (_, __) async => false);
    await selectAction(tester, 'Rename');
    expect(find.text('Personal Documents'), findsOneWidget);
    expect(find.text('Policy.pdf'), findsOneWidget);
  });

  testWidgets('successful Recycle Bin move closes the stale browser', (tester) async {
    await openActionBrowser(tester, onTrash: (_, __) async => true);
    await selectAction(tester, 'Move to Recycle Bin');
    expect(find.text('Open browser'), findsOneWidget);
    expect(find.text('Phone Storage'), findsNothing);
  });

  testWidgets('Share does not close the selected folder browser', (tester) async {
    await openActionBrowser(tester, onShare: (_, __) async {});
    await selectAction(tester, 'Share');
    expect(find.text('Personal Documents'), findsOneWidget);
    expect(find.text('Policy.pdf'), findsOneWidget);
  });
}
