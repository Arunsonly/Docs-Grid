import 'package:docs_grid/features/documents/data/document_repository.dart';
import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:docs_grid/features/folders/domain/folder.dart';
import 'package:docs_grid/features/folders/presentation/folders_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeDocuments extends DocumentRepository {
  final pdf = DocumentRecord(
    id: 'pdf-1',
    name: 'Annual_Statement',
    storagePath: '/test/Annual_Statement.pdf',
    sizeBytes: 1024,
    createdAt: DateTime(2026, 11, 20),
    isFavorite: false,
  );

  @override
  Future<int> countInFolder(String? folderId) async => 0;

  @override
  Future<FolderDocumentPage> listInFolderPage(
    String? folderId, {
    int pageSize = 60,
    String? afterName,
    String? afterId,
  }) async => const FolderDocumentPage(records: [], hasMore: false);

  @override
  Future<List<DocumentRecord>> list({
    String query = '',
    bool favoritesOnly = false,
    bool recentOnly = false,
  }) async {
    if (query.isEmpty ||
        pdf.name.toLowerCase().contains(query.trim().toLowerCase())) {
      return [pdf];
    }
    return [];
  }
}

class _FakeFolders extends FolderRepository {
  @override
  Future<List<Folder>> childrenOf(String? parentId, {int? previewLimit})
      async => const <Folder>[];
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Grid uses only filename matching and has no OCR option',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: FoldersScreen(
        folderRepository: _FakeFolders(),
        documentRepository: _FakeDocuments(),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '982731');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grid-pdf-pdf-1')), findsNothing);
    expect(find.byKey(const ValueKey('ocr-search-mode-selector')), findsNothing);
    await tester.enterText(find.byType(TextField).first, 'Annual');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grid-pdf-pdf-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
