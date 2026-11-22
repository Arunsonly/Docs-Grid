import 'package:docs_grid/features/documents/data/document_repository.dart';
import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:docs_grid/features/folders/domain/folder.dart';
import 'package:docs_grid/features/folders/presentation/folders_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestFolders extends FolderRepository {
  final entries = [
    Folder(
      id: 'arun', name: 'Arun',
      createdAt: DateTime(2026), updatedAt: DateTime(2026), pdfCount: 2,
    ),
    Folder(
      id: 'indian', name: 'Indian',
      createdAt: DateTime(2026), updatedAt: DateTime(2026),
    ),
  ];
  int detailsRequests = 0;
  List<String>? reordered;

  @override
  Future<List<Folder>> childrenOf(String? parentId, {int? previewLimit}) async {
    if (parentId != null) return [];
    return previewLimit == null ? entries : entries.take(previewLimit).toList();
  }

  @override
  Future<int> countDirectChildren(String? parentId) async =>
      parentId == null ? entries.length : 0;

  @override
  Future<FolderSelectionDetails> selectionDetails(Set<String> ids) async {
    detailsRequests++;
    return FolderSelectionDetails(
      selectedFolderCount: ids.length,
      nestedFolderCount: 2,
      pdfCount: 3,
      totalPdfSizeBytes: 10240,
    );
  }

  @override
  Future<void> reorderChildren(String? parentId, List<String> orderedIds) async {
    reordered = orderedIds;
  }
}

class _TestDocuments extends DocumentRepository {
  @override
  Future<int> countInFolder(String? folderId) async => 0;

  @override
  Future<FolderDocumentPage> listInFolderPage(
    String? folderId, {
    int pageSize = 60,
    String? afterName,
    String? afterId,
  }) async => const FolderDocumentPage(records: [], hasMore: false);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> showGrid(WidgetTester tester, _TestFolders folders,
      {VoidCallback? onSettings}) async {
    tester.view.physicalSize = const Size(900, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('DocsGrid')),
        body: FoldersScreen(
          folderRepository: folders,
          documentRepository: _TestDocuments(),
          onOpenSettings: onSettings,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('long press auto-selects, replaces only folder header and back clears',
      (tester) async {
    await showGrid(tester, _TestFolders());
    expect(find.byKey(const ValueKey('grid-folder-normal-more')), findsOneWidget);
    expect(find.text('DocsGrid'), findsOneWidget);
    expect(find.byTooltip('Create folder'), findsOneWidget);

    await tester.longPress(find.text('Arun'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grid-folder-selection-header')), findsOneWidget);
    expect(find.byKey(const ValueKey('grid-floating-selection-position')), findsOneWidget);
    expect(tester.getBottomRight(
        find.byKey(const ValueKey('grid-folder-selection-header'))).dy,
        greaterThan(1300), reason: 'Folder actions float near the bottom.');
    expect(find.byKey(const ValueKey('grid-folder-normal-more')), findsNothing);
    expect(find.byTooltip('Create folder'), findsNothing);
    expect(find.text('DocsGrid'), findsOneWidget); // AppBar never replaced.
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byIcon(Icons.select_all), findsOneWidget);
    expect(find.byTooltip('Move selected folders'), findsOneWidget);
    expect(find.byTooltip('Move selected folders to Recycle Bin'), findsOneWidget);
    expect(tester.widgetList<Checkbox>(find.byType(Checkbox))
        .where((checkbox) => checkbox.value == true).length, 1);

    await tester.tap(find.byKey(const ValueKey('grid-folder-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(tester.widgetList<Checkbox>(find.byType(Checkbox))
        .where((checkbox) => checkbox.value == true).length, 2);

    await tester.tap(find.byKey(const ValueKey('grid-folder-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grid-folder-selection-header')), findsNothing);
    expect(find.byKey(const ValueKey('grid-folder-normal-more')), findsOneWidget);
    expect(find.byTooltip('Create folder'), findsOneWidget);
    expect(find.text('DocsGrid'), findsOneWidget);
  });

  testWidgets('Details shows nested counts and summed PDF size without mutation',
      (tester) async {
    final folders = _TestFolders();
    await showGrid(tester, folders);
    await tester.longPress(find.text('Arun'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('grid-folder-selected-more')));
    await tester.pumpAndSettle();
    expect(find.text('Details'), findsOneWidget);
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text('Selected folders: 1'), findsOneWidget);
    expect(find.text('Folders inside: 2'), findsOneWidget);
    expect(find.text('PDFs inside: 3'), findsOneWidget);
    expect(find.text('Total PDF size: 10.0 KB'), findsOneWidget);
    expect(folders.detailsRequests, 1);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
  });

  testWidgets('normal three dots keep Rearrange and open existing Settings',
      (tester) async {
    final folders = _TestFolders();
    var settingsOpens = 0;
    await showGrid(tester, folders, onSettings: () => settingsOpens++);
    await tester.tap(find.byKey(const ValueKey('grid-folder-normal-more')));
    await tester.pumpAndSettle();
    expect(find.text('Rearrange'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(settingsOpens, 1);

    await tester.tap(find.byKey(const ValueKey('grid-folder-normal-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rearrange'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('finish-folder-reorder')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('finish-folder-reorder')));
    await tester.pumpAndSettle();
    expect(folders.reordered, ['arun', 'indian']);
  });
}
