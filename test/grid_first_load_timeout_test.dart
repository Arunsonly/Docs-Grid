import 'dart:async';

import 'package:docs_grid/features/documents/data/document_repository.dart';
import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:docs_grid/features/folders/domain/folder.dart';
import 'package:docs_grid/features/folders/presentation/folders_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SometimesStalledFolders extends FolderRepository {
  _SometimesStalledFolders({this.stallFirst = false});
  final bool stallFirst;
  final Completer<List<Folder>> firstRead = Completer<List<Folder>>();
  int calls = 0;

  @override
  Future<List<Folder>> childrenOf(String? parentId, {int? previewLimit}) {
    calls++;
    if (stallFirst && calls == 1) return firstRead.future;
    return Future.value(<Folder>[]);
  }

  @override
  Future<int> countDirectChildren(String? parentId) async => 0;
}

class _SometimesStalledPdfs extends DocumentRepository {
  _SometimesStalledPdfs({this.stallFirst = false});
  final bool stallFirst;
  final Completer<FolderDocumentPage> firstRead =
      Completer<FolderDocumentPage>();
  int calls = 0;

  @override
  Future<int> countInFolder(String? folderId) async => 0;

  @override
  Future<FolderDocumentPage> listInFolderPage(
    String? folderId, {
    int pageSize = 60,
    String? afterName,
    String? afterId,
  }) {
    calls++;
    if (stallFirst && calls == 1) return firstRead.future;
    return Future.value(const FolderDocumentPage(
      records: <DocumentRecord>[], hasMore: false));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> openGrid(WidgetTester tester, FolderRepository folders,
      DocumentRepository docs) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FoldersScreen(
          folderRepository: folders,
          documentRepository: docs,
          loadTimeout: const Duration(milliseconds: 350),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('fresh Grid never waits indefinitely for folder provider', (tester) async {
    final folders = _SometimesStalledFolders(stallFirst: true);
    await openGrid(tester, folders, _SometimesStalledPdfs());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('Could not load folders.'), findsOneWidget);
    expect(find.textContaining('Grid is taking too long'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('All Your Docs. One Smart Place.'), findsOneWidget);
    expect(folders.calls, greaterThanOrEqualTo(2));
  });

  testWidgets('fresh Grid retries a stalled first PDF page', (tester) async {
    final docs = _SometimesStalledPdfs(stallFirst: true);
    await openGrid(tester, _SometimesStalledFolders(), docs);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('Could not load PDFs.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('All Your Docs. One Smart Place.'), findsOneWidget);
    expect(docs.calls, greaterThanOrEqualTo(2));
  });
}
