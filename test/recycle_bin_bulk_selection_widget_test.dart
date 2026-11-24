import 'package:docs_grid/features/documents/data/document_repository.dart';
import 'package:docs_grid/features/documents/presentation/recycle_bin_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

DocumentRecord samplePdf(String id, String name) => DocumentRecord(
  id: id,
  name: name,
  storagePath: '/mock/$name.pdf',
  sizeBytes: 2048,
  createdAt: DateTime(2026, 11, 22),
  isFavorite: false,
);

class _FakeTrash {
  final deletedFolders = <String>[];
  final deletedPdfs = <String>[];
  final restoredFolders = <String>[];
  final restoredPdfs = <String>[];
  final changed = <bool>[];
  final failedFolderIds = <String>{};
  var inspected = 0;

  List<Map<String, Object?>> get folders => [
    {
      'id': 'folder-d', 'name': 'D', 'folder_count': 1,
      'pdf_count': 0, 'deleted_at': '2026-11-22',
    },
    {
      'id': 'folder-fire', 'name': 'Fire', 'folder_count': 1,
      'pdf_count': 0, 'deleted_at': '2026-11-22',
    },
  ];

  Future<Map<String, Object?>> inspect(String id) async {
    inspected++;
    return {
      'rootName': 'Fire folder details',
      'folders': [
        {'id': id, 'name': 'Fire', 'path': 'Insurance / Fire'},
      ],
      'documents': <Map<String, Object?>>[],
    };
  }

  Future<void> deleteFolder(String id) async {
    if (failedFolderIds.contains(id)) throw StateError('Folder is inaccessible');
    deletedFolders.add(id);
  }

  Future<void> deletePdf(DocumentRecord pdf) async {
    deletedPdfs.add(pdf.id);
  }

  Future<void> restoreFolder(String id) async {
    restoredFolders.add(id);
  }

  Future<void> restorePdf(DocumentRecord pdf) async {
    restoredPdfs.add(pdf.id);
  }

  Future<void> onChanged({required bool pdfChanged}) async {
    changed.add(pdfChanged);
  }
}

void main() {
  Future<void> showTrash(WidgetTester tester, _FakeTrash fake,
      {List<DocumentRecord>? documents}) async {
    tester.view.physicalSize = const Size(900, 1550);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) => Center(
          child: FilledButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => RecycleBinDialog(
                folders: fake.folders,
                pdfs: documents ?? [samplePdf('pdf-1', 'Policy')],
                inspectFolder: fake.inspect,
                restoreFolder: fake.restoreFolder,
                deleteFolder: fake.deleteFolder,
                restorePdf: fake.restorePdf,
                deletePdf: fake.deletePdf,
                onChanged: fake.onChanged,
              ),
            ),
            child: const Text('Show Recycle Bin'),
          ),
        )),
      ),
    ));
    await tester.tap(find.text('Show Recycle Bin'));
    await tester.pumpAndSettle();
  }

  testWidgets('long-press folder starts selection, Back clears before closing dialog',
      (tester) async {
    final fake = _FakeTrash();
    await showTrash(tester, fake);
    expect(find.text('Recycle Bin'), findsOneWidget);
    expect(find.byKey(const ValueKey('recycle-select-all')), findsNothing);
    expect(find.byKey(const ValueKey('recycle-folder-menu-folder-d')), findsOneWidget);

    await tester.longPress(find.text('D'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byKey(const ValueKey('recycle-delete-selected')), findsOneWidget);
    expect(find.byKey(const ValueKey('recycle-folder-menu-folder-d')), findsNothing);
    expect(tester.widget<Checkbox>(
      find.byKey(const ValueKey('recycle-folder-check-folder-d')),
    ).value, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Recycle Bin'), findsOneWidget);
    expect(find.byKey(const ValueKey('recycle-select-all')), findsNothing);
    expect(find.byKey(const ValueKey('recycle-folder-menu-folder-d')), findsOneWidget);
    expect(fake.deletedFolders, isEmpty);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Recycle Bin'), findsNothing);
  });

  testWidgets('PDF long press, Select All covers both types, and Cancel is safe',
      (tester) async {
    final fake = _FakeTrash();
    await showTrash(tester, fake);
    await tester.longPress(find.text('Policy.pdf'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('recycle-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);
    expect(find.text('Deselect All'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('recycle-delete-selected')));
    await tester.pumpAndSettle();
    expect(find.text('Delete permanently?'), findsOneWidget);
    expect(find.textContaining('Delete 2 folder(s) and 1 PDF(s) permanently?'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);
    expect(fake.deletedFolders, isEmpty);
    expect(fake.deletedPdfs, isEmpty);

    await tester.tap(find.byKey(const ValueKey('recycle-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
    final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('recycle-delete-selected')));
    expect(button.onPressed, isNull);
  });

  testWidgets('one confirmed Delete Selected removes chosen folders and PDFs',
      (tester) async {
    final fake = _FakeTrash();
    await showTrash(tester, fake);
    await tester.longPress(find.text('Fire'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Policy.pdf'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('recycle-delete-selected')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete permanently'));
    await tester.pumpAndSettle();
    expect(fake.deletedFolders, ['folder-fire']);
    expect(fake.deletedPdfs, ['pdf-1']);
    expect(fake.changed, [true]);
    expect(find.text('Fire'), findsNothing);
    expect(find.text('Policy.pdf'), findsNothing);
    expect(find.text('D'), findsOneWidget);
    expect(find.byKey(const ValueKey('recycle-select-all')), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('partial failure keeps failed folder selected, successes removed',
      (tester) async {
    final fake = _FakeTrash()..failedFolderIds.add('folder-fire');
    await showTrash(tester, fake);
    await tester.longPress(find.text('D'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recycle-select-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recycle-delete-selected')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete permanently'));
    await tester.pumpAndSettle();

    expect(fake.deletedFolders, ['folder-d']);
    expect(fake.deletedPdfs, ['pdf-1']);
    expect(fake.changed, [true]);
    expect(find.text('Some items could not be deleted'), findsOneWidget);
    await tester.tap(find.text('Close').last);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.text('Fire'), findsOneWidget);
    expect(find.text('D'), findsNothing);
    expect(find.text('Policy.pdf'), findsNothing);
  });

  testWidgets('normal folder details and individual Restore remain available',
      (tester) async {
    final fake = _FakeTrash();
    await showTrash(tester, fake);
    await tester.tap(find.text('Fire'));
    await tester.pumpAndSettle();
    expect(find.text('Insurance / Fire'), findsOneWidget);
    expect(fake.inspected, 1);
    await tester.tap(find.text('Close').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('recycle-folder-menu-folder-d')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore folder'));
    await tester.pumpAndSettle();
    expect(fake.restoredFolders, ['folder-d']);
    expect(fake.changed, [false]);
    expect(find.text('D'), findsNothing);
    expect(find.text('Fire'), findsOneWidget);
  });
}
