import 'package:docs_grid/features/documents/presentation/phone_move_folder_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Phone Move lists only safe accessible folders, rejects same folder, picks Insurance',
      (tester) async {
    tester.view.physicalSize = const Size(850, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    PhoneFolderDestination? selected;
    const root = 'file:///storage/emulated/0';
    final reads = <String>[];

    Future<List<Map<String, Object?>>> list(String uri) async {
      reads.add(uri);
      if (uri == root) {
        return [
          {'isDirectory': true, 'uri': '$root/Download', 'name': 'Download'},
          {'isDirectory': true, 'uri': '$root/Insurance', 'name': 'Insurance'},
          {'isDirectory': true,
           'uri': '$root/Android/media/com.docsgrid', 'name': 'DocsGrid'},
          {'isDirectory': true,
           'uri': '$root/.Trash', 'name': '.Trash'},
          {'isDirectory': false, 'uri': '$root/Policy.pdf', 'name': 'Policy.pdf'},
        ];
      }
      return const [];
    }

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
      builder: (context) => ElevatedButton(
        onPressed: () async {
          selected = await showModalBottomSheet<PhoneFolderDestination>(
            context: context,
            isScrollControlled: true,
            builder: (_) => FractionallySizedBox(
              heightFactor: 0.75,
              child: PhoneMoveFolderPicker(
                roots: const [{'uri': root, 'name': 'Internal storage'}],
                sourceFolderPath: 'Internal/Download',
                listDirectory: list,
                createDirectory: (_, __) async =>
                    throw StateError('Not creating a folder in this test'),
              ),
            ),
          );
        },
        child: const Text('Open picker'),
      ),
    ))));
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    expect(find.text('Internal storage'), findsOneWidget);
    await tester.tap(find.text('Internal storage'));
    await tester.pumpAndSettle();
    expect(reads, [root]);
    expect(find.text('DocsGrid'), findsNothing);
    expect(find.text('.Trash'), findsNothing);
    expect(find.text('Policy.pdf'), findsNothing);

    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    final moveButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey('phone-move-confirm')));
    expect(moveButton.onPressed, isNull,
        reason: 'A Phone PDF must not be moved into its own source folder.');
    await tester.tap(find.byKey(const ValueKey('phone-move-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Insurance'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('phone-move-confirm')));
    await tester.pumpAndSettle();
    expect(selected?.uri, '$root/Insurance');
    expect(selected?.path, 'Internal storage/Insurance');
    expect(tester.takeException(), isNull);
  });

  testWidgets('batch picker offers Grid independently from physical Phone folders',
      (tester) async {
    PhoneFolderDestination? selected;
    var reads = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
      builder: (context) => ElevatedButton(
        onPressed: () async {
          selected = await showModalBottomSheet<PhoneFolderDestination>(
            context: context,
            isScrollControlled: true,
            builder: (_) => FractionallySizedBox(
              heightFactor: 0.75,
              child: PhoneMoveFolderPicker(
                roots: const [{'uri': 'file:///root', 'name': 'Internal storage'}],
                allowGridDestination: true,
                listDirectory: (_) async { reads++; return []; },
                createDirectory: (_, __) async => throw StateError('Not needed'),
              ),
            ),
          );
        },
        child: const Text('Open picker'),
      ),
    ))));
    await tester.tap(find.text('Open picker'));
    await tester.pumpAndSettle();
    expect(find.text('Internal storage'), findsOneWidget);
    expect(find.text('Grid Storage'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('phone-move-grid-destination')));
    await tester.pumpAndSettle();
    expect(selected?.isGrid, isTrue);
    expect(selected?.uri, isEmpty);
    expect(reads, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('picker cancellation makes no move or file-storage operation',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
      builder: (context) => ElevatedButton(
        onPressed: () async {
          await showModalBottomSheet<PhoneFolderDestination>(
            context: context,
            isScrollControlled: true,
            builder: (_) => FractionallySizedBox(
              heightFactor: 0.6,
              child: PhoneMoveFolderPicker(
                roots: const [{'uri': 'file:///root', 'name': 'Internal storage'}],
                listDirectory: (_) async {
                  calls++;
                  return const [];
                },
                createDirectory: (_, __) async =>
                    throw StateError('No directory should be created.'),
              ),
            ),
          );
        },
        child: const Text('Choose'),
      ),
    ))));
    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });
}
