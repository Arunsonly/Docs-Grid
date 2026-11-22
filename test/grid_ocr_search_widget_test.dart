import 'package:docs_grid/features/documents/data/document_repository.dart';
import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:docs_grid/features/folders/domain/folder.dart';
import 'package:docs_grid/features/folders/presentation/folders_screen.dart';
import 'package:docs_grid/features/tools/document_tools_service.dart';
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

class _FakeTextTools extends DocumentToolsService {
  var indexed = 0;

  @override
  Future<List<Map<String, Object?>>> searchText(String query) async {
    if (query.toLowerCase() != '982731') return const [];
    return const [
      {'id': 'pdf-1', 'name': 'Annual_Statement', 'extracted_text': '982731'}
    ];
  }

  @override
  Future<OcrSearchIndexSummary> indexPendingPdfsForSearch({
    bool Function()? shouldCancel,
    void Function(int completed, int total)? onProgress,
  }) async {
    indexed++;
    onProgress?.call(1, 1);
    return const OcrSearchIndexSummary(indexed: 1, failed: 0, skipped: 0);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Grid finds PDF text only after single-tap OCR activation',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final tools = _FakeTextTools();
    await tester.pumpWidget(MaterialApp(
      home: FoldersScreen(
        folderRepository: _FakeFolders(),
        documentRepository: _FakeDocuments(),
        ocrTools: tools,
        ocrSearchAvailable: true,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '982731');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grid-pdf-pdf-1')), findsNothing);
    expect(tools.indexed, 0);

    await tester.tap(find.byKey(const ValueKey('ocr-search-mode-selector')));
    await tester.pumpAndSettle();
    expect(tools.indexed, 1);
    expect(find.byKey(const ValueKey('grid-pdf-pdf-1')), findsOneWidget);
    expect(find.byTooltip('Turn off OCR search'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ocr-search-mode-selector')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grid-pdf-pdf-1')), findsNothing);
    expect(find.byTooltip('Turn on OCR search'), findsOneWidget);
    expect(tools.indexed, 1, reason: 'Name-only mode must never start OCR.');
  });
}
