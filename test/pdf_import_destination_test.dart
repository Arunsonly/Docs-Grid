import 'package:flutter_test/flutter_test.dart';
import 'package:docs_grid/features/documents/data/document_repository.dart';

void main() {
  group('resolvePdfImportDestination', () {
    test('prefers the portable DocsGrid Documents folder on Android', () {
      final result = resolvePdfImportDestination(
        isAndroid: true,
        portableDocumentsUri: 'file:///storage/emulated/0/Android/media/com.docsgrid/My%20Files/Unfiled',
        selectedFolderUri: 'content://selected-tree',
      );

      expect(result.uri, startsWith('file://'));
      expect(result.usesPrivateStorage, isFalse);
    });

    test('falls back to selected SAF folder when portable storage is unavailable', () {
      final result = resolvePdfImportDestination(
        isAndroid: true,
        selectedFolderUri: 'content://com.android.externalstorage.documents/tree/primary%3ADocuments',
      );

      expect(result.uri, startsWith('content://'));
      expect(result.usesPrivateStorage, isFalse);
    });

    test('requires a shared destination instead of creating another Android library', () {
      final result = resolvePdfImportDestination(isAndroid: true);

      expect(result.uri, isNull);
      expect(result.usesPrivateStorage, isFalse);
      expect(result.requiresStorageSetup, isTrue);
    });

    test('uses app-private storage on non-Android when no shared target exists', () {
      final result = resolvePdfImportDestination(isAndroid: false);

      expect(result.uri, isNull);
      expect(result.usesPrivateStorage, isTrue);
      expect(result.requiresStorageSetup, isFalse);
    });

    test('uses the selected folder on non-Android platforms', () {
      final result = resolvePdfImportDestination(
        isAndroid: false,
        portableDocumentsUri: 'ignored://portable',
        selectedFolderUri: 'file:///selected-folder',
      );

      expect(result.uri, 'file:///selected-folder');
      expect(result.usesPrivateStorage, isFalse);
    });

    test('uses an explicitly resolved subfolder over the root destination', () {
      final result = resolvePdfImportDestination(
        isAndroid: true,
        portableDocumentsUri: 'file:///portable-documents',
        selectedFolderUri: 'content://selected-root',
        targetFolderUri: 'content://selected-subfolder',
      );

      expect(result.uri, 'content://selected-subfolder');
      expect(result.usesPrivateStorage, isFalse);
    });
  });
}
