import 'package:docs_grid/features/documents/data/document_repository.dart';
import 'package:docs_grid/features/documents/presentation/document_thumbnail.dart';
import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:docs_grid/features/folders/domain/folder.dart';
import 'package:docs_grid/features/folders/presentation/folders_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Folders extends FolderRepository {
  _Folders(this.rootFolders);
  final List<Folder> rootFolders;
  final List<int?> requestedPreviewLimits = [];

  @override
  Future<List<Folder>> childrenOf(String? parentId, {int? previewLimit}) async {
    requestedPreviewLimits.add(previewLimit);
    final items = parentId == null ? rootFolders : const <Folder>[];
    return previewLimit == null ? items : items.take(previewLimit).toList();
  }

  @override
  Future<int> countDirectChildren(String? parentId) async =>
      parentId == null ? rootFolders.length : 0;
}

class _Documents extends DocumentRepository {
  _Documents(this.all);
  final List<DocumentRecord> all;
  int pageCalls = 0;
  int fullListCalls = 0;

  @override
  Future<FolderDocumentPage> listInFolderPage(String? folderId, {
    int pageSize = 60,
    String? afterName,
    String? afterId,
  }) async {
    pageCalls++;
    final records = all.where((item) => item.folderId == folderId).toList()
      ..sort((a, b) {
        final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return byName != 0 ? byName : a.id.compareTo(b.id);
      });
    var start = 0;
    if (afterName != null) {
      start = records.indexWhere((item) =>
          item.name.toLowerCase().compareTo(afterName.toLowerCase()) > 0 ||
          (item.name.toLowerCase() == afterName.toLowerCase() &&
              item.id.compareTo(afterId!) > 0));
      if (start == -1) start = records.length;
    }
    final page = records.skip(start).take(pageSize + 1).toList();
    final hasMore = page.length > pageSize;
    final visible = page.take(pageSize).toList(growable: false);
    return FolderDocumentPage(
      records: visible,
      hasMore: hasMore,
      nextName: hasMore && visible.isNotEmpty ? visible.last.name : null,
      nextId: hasMore && visible.isNotEmpty ? visible.last.id : null,
    );
  }

  @override
  Future<int> countInFolder(String? folderId) async =>
      all.where((item) => item.folderId == folderId).length;

  @override
  Future<List<DocumentRecord>> listInFolder(String? folderId) async {
    fullListCalls++;
    return all.where((item) => item.folderId == folderId).toList();
  }
}

Folder _folder(int index) => Folder(
  id: 'folder-$index',
  name: 'Folder ${index.toString().padLeft(3, '0')}',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

DocumentRecord _pdf(int index) => DocumentRecord(
  id: 'doc-$index',
  name: 'Policy_${index.toString().padLeft(3, '0')}',
  storagePath: 'content://media/$index',
  sizeBytes: 2048,
  createdAt: DateTime(2026, 1, 1),
  isFavorite: false,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  void viewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('Grid virtualizes 220 folders, without eagerly building all Cards',
      (tester) async {
    viewport(tester);
    final folders = _Folders(List.generate(220, _folder));
    final documents = _Documents(const []);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FoldersScreen(
        folderRepository: folders,
        documentRepository: documents,
      )),
    ));
    await tester.pumpAndSettle();
    expect(find.text('220 folders · 0 PDFs'), findsOneWidget);
    expect(find.byKey(const ValueKey('folder-folder-0')), findsOneWidget);
    expect(find.byType(Card).evaluate().length, lessThan(50));
    expect(find.byKey(const ValueKey('folder-folder-219')), findsNothing);
    // Background metadata work is optional and strictly bounded.
    expect(folders.requestedPreviewLimits.whereType<int>().length,
        lessThanOrEqualTo(2));
    expect(documents.fullListCalls, 0);
  });

  testWidgets('Grid progressively loads a page ahead without changing totals',
      (tester) async {
    viewport(tester);
    final folders = _Folders(const []);
    final documents = _Documents(List.generate(155, _pdf));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FoldersScreen(
        folderRepository: folders,
        documentRepository: documents,
      )),
    ));
    await tester.pumpAndSettle();
    expect(find.text('0 folders · 155 PDFs'), findsOneWidget);
    expect(documents.pageCalls, greaterThanOrEqualTo(1));
    expect(documents.fullListCalls, 0);
    expect(find.byType(DocumentThumbnail).evaluate().length, lessThan(60));

    await tester.scrollUntilVisible(
      find.text('Policy_085.pdf'), 420,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 35,
    );
    await tester.pumpAndSettle();
    expect(find.text('Policy_085.pdf'), findsOneWidget);
    expect(find.text('0 folders · 155 PDFs'), findsOneWidget);
    expect(documents.pageCalls, greaterThanOrEqualTo(2));
    expect(documents.fullListCalls, 0);
  });

  testWidgets('Select all still selects PDFs outside the visible page',
      (tester) async {
    viewport(tester);
    final documents = _Documents(List.generate(135, _pdf));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FoldersScreen(
        folderRepository: _Folders(const []),
        documentRepository: documents,
      )),
    ));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Policy_000.pdf'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();
    expect(find.text('135 selected'), findsOneWidget);
    expect(documents.fullListCalls, 1);
  });
}
