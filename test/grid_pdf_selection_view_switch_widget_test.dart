import 'package:docs_grid/features/documents/data/document_repository.dart';
import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:docs_grid/features/folders/domain/folder.dart';
import 'package:docs_grid/features/folders/presentation/folders_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Folder _folder(String id, {String? parentId}) => Folder(
      id: id,
      name: id,
      parentId: parentId,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

DocumentRecord _pdf(String id, int size, {String? folderId}) => DocumentRecord(
      id: id,
      name: id,
      folderId: folderId,
      storagePath: 'content://test/$id',
      sizeBytes: size,
      createdAt: DateTime(2026),
      isFavorite: false,
    );

class _Folders extends FolderRepository {
  @override
  Future<List<Folder>> childrenOf(String? parentId, {int? previewLimit}) async {
    final result = parentId == null
        ? [_folder('Arun'), _folder('Indian')]
        : parentId == 'Arun' ? [_folder('H', parentId: 'Arun')] : <Folder>[];
    return previewLimit == null ? result : result.take(previewLimit).toList();
  }

  @override
  Future<int> countDirectChildren(String? parentId) async =>
      parentId == null ? 2 : parentId == 'Arun' ? 1 : 0;
}

class _Documents extends DocumentRepository {
  final docs = [
    _pdf('Policy_A', 1024),
    _pdf('Policy_B', 2048),
    _pdf('Nested', 4096, folderId: 'Arun'),
    _pdf('Deep', 8192, folderId: 'H'),
  ];
  int fullListReads = 0;

  @override
  Future<int> countInFolder(String? folderId) async =>
      docs.where((d) => d.folderId == folderId).length;

  @override
  Future<FolderDocumentPage> listInFolderPage(
    String? folderId, {
    int pageSize = 60,
    String? afterName,
    String? afterId,
  }) async => FolderDocumentPage(
        records: docs.where((d) => d.folderId == folderId).toList(),
        hasMore: false,
      );

  @override
  Future<List<DocumentRecord>> listInFolder(String? folderId) async {
    fullListReads++;
    return docs.where((d) => d.folderId == folderId).toList();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpGrid(WidgetTester tester, _Documents docs) async {
    tester.view.physicalSize = const Size(900, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('DocsGrid')),
        body: FoldersScreen(
          folderRepository: _Folders(),
          documentRepository: docs,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('PDF hold replaces the Folders row, keeps Share and gives correct Details',
      (tester) async {
    final docs = _Documents();
    await pumpGrid(tester, docs);
    expect(find.byKey(const ValueKey('grid-folder-normal-more')), findsOneWidget);
    expect(find.text('DocsGrid'), findsOneWidget);

    await tester.longPress(find.text('Policy_A.pdf'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grid-pdf-selection-header')), findsOneWidget);
    expect(find.byKey(const ValueKey('grid-folder-normal-more')), findsNothing);
    expect(find.byTooltip('Create folder'), findsNothing);
    expect(find.text('DocsGrid'), findsOneWidget);
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byKey(const ValueKey('grid-pdf-share-selected')), findsOneWidget);
    expect(find.byKey(const ValueKey('grid-pdf-move-selected')), findsOneWidget);
    expect(find.byKey(const ValueKey('grid-pdf-delete-selected')), findsOneWidget);
    expect(tester.widgetList<Checkbox>(find.byType(Checkbox))
        .where((checkbox) => checkbox.value == true).length, 1);

    await tester.tap(find.byKey(const ValueKey('grid-pdf-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(tester.widgetList<Checkbox>(find.byType(Checkbox))
        .where((checkbox) => checkbox.value == true).length, 2);
    await tester.tap(find.byKey(const ValueKey('grid-pdf-selected-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    expect(find.text('Selected PDFs: 2'), findsOneWidget);
    expect(find.text('Total PDF size: 3.0 KB'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('grid-pdf-select-all')));
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
    expect(find.byKey(const ValueKey('grid-pdf-selection-header')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grid-pdf-selection-header')), findsNothing);
    expect(find.byKey(const ValueKey('grid-folder-normal-more')), findsOneWidget);
  });

  testWidgets('Grid/List toggle switches both folder and PDF cards and retains actions',
      (tester) async {
    final docs = _Documents();
    await pumpGrid(tester, docs);
    expect(find.byKey(const ValueKey('grid-folder-rows')), findsOneWidget);
    expect(find.byKey(const ValueKey('grid-pdf-rows')), findsOneWidget);
    expect(find.byTooltip('Grid view'), findsOneWidget);

    final menu = find.byKey(const ValueKey('grid-folder-normal-more'));
    final toggle = find.byKey(const ValueKey('grid-view-mode-toggle'));
    final create = find.byTooltip('Create folder');
    final header = tester.getTopLeft(menu);
    expect(tester.getTopLeft(toggle).dx, greaterThan(header.dx));
    expect(tester.getTopLeft(toggle).dx, lessThan(tester.getTopLeft(create).dx));

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grid-folder-tiles')), findsOneWidget);
    expect(find.byKey(const ValueKey('grid-pdf-tiles')), findsOneWidget);
    expect(find.byTooltip('List view'), findsOneWidget);
    expect(find.byKey(const ValueKey('folder-Arun')), findsOneWidget);
    expect(find.byKey(const ValueKey('grid-pdf-Policy_A')), findsOneWidget);
    expect(docs.fullListReads, 0); // Toggle must not re-query whole folder.

    await tester.tap(find.byTooltip('Folder actions').first);
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Move'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Policy_A.pdf'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grid-pdf-selection-header')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grid-folder-rows')), findsOneWidget);
    expect(find.byKey(const ValueKey('grid-pdf-rows')), findsOneWidget);
    expect(find.byTooltip('Grid view'), findsOneWidget);
  });

  testWidgets('Grid tiles work in a nested folder and preserve prior view mode',
      (tester) async {
    final docs = _Documents();
    await pumpGrid(tester, docs);
    await tester.tap(find.byKey(const ValueKey('grid-view-mode-toggle')));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('docsgrid_grid_tab_tiles_v1'), isTrue);

    await tester.tap(find.text('Arun'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grid-folder-tiles')), findsOneWidget);
    expect(find.byKey(const ValueKey('grid-pdf-tiles')), findsOneWidget);
    await tester.longPress(find.text('Nested.pdf'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grid-pdf-selection-header')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Arun'), findsWidgets); // Still inside the folder.
    expect(find.byKey(const ValueKey('grid-pdf-selection-header')), findsNothing);
    await tester.longPress(find.text('H'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grid-folder-selection-header')), findsOneWidget);
  });
}
