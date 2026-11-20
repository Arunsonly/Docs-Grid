import 'package:docs_grid/core/storage/folder_preview_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.now().toUtc();

  test('Grid preview round trips folder counts and PDF sizes as metadata', () {
    final view = FolderPreview(
      key: FolderPreviewCache.gridKey('folder-17'),
      savedAt: now,
      items: const [
        FolderPreviewItem(name: 'Motor', isFolder: true, pdfCount: 125),
        FolderPreviewItem(name: 'Policy.pdf', isFolder: false, sizeBytes: 8192),
      ],
    );
    final encoded = view.toJson();
    final restored = FolderPreview.fromJson(encoded, view.key);
    expect(restored, isNotNull);
    expect(restored!.folderCount, 1);
    expect(restored.pdfCount, 1);
    expect(restored.items.first.pdfCount, 125);
    expect(restored.items.last.sizeBytes, 8192);
    expect(encoded.toString(), isNot(contains('content://')));
    expect(encoded.toString(), isNot(contains('storage_uri')));
    expect(encoded.toString(), isNot(contains('sha256')));
  });

  test('Cache does not mix folders or Android storage roots', () {
    final gridRoot = FolderPreviewCache.gridKey(null);
    final gridChild = FolderPreviewCache.gridKey('folder-17');
    final phoneA = FolderPreviewCache.phoneKey(
      'content://tree/first', 'Internal/Download',
    );
    final phoneB = FolderPreviewCache.phoneKey(
      'content://tree/second', 'Internal/Download',
    );
    expect({gridRoot, gridChild, phoneA, phoneB}, hasLength(4));
    final view = FolderPreview(
      key: phoneA,
      savedAt: now,
      items: const [FolderPreviewItem(
        name: 'Example.pdf', isFolder: false, sizeBytes: 300,
      )],
    );
    expect(FolderPreview.fromJson(view.toJson(), phoneA), isNotNull);
    expect(FolderPreview.fromJson(view.toJson(), phoneB), isNull);
    expect(FolderPreview.fromJson(view.toJson(), gridChild), isNull);
  });

  test('Invalid, expired or future-dated saved previews fail closed', () {
    const key = 'grid:folder-17';
    final good = FolderPreview(
      key: key,
      savedAt: now,
      items: const [FolderPreviewItem(name: 'Safe.pdf', isFolder: false)],
    ).toJson();
    expect(FolderPreview.fromJson({...good, 'schema': 42}, key), isNull);
    expect(FolderPreview.fromJson({...good, 'items': 'corrupt'}, key), isNull);
    expect(FolderPreview.fromJson({
      ...good, 'savedAt': now.subtract(const Duration(days: 31)).toIso8601String(),
    }, key), isNull);
    expect(FolderPreview.fromJson({
      ...good, 'savedAt': now.add(const Duration(days: 1)).toIso8601String(),
    }, key), isNull);
    expect(FolderPreview.fromJson({
      ...good, 'items': [{'isFolder': true, 'name': null}],
    }, key), isNull);
    expect(FolderPreview.fromJson({
      ...good, 'items': List.filled(FolderPreviewCache.maxItemsPerFolder + 1, 1),
    }, key), isNull);
  });

  test('Malformed count and size never turn into a negative total', () {
    const key = 'grid:folder-17';
    final parsed = FolderPreview.fromJson({
      'schema': 1, 'key': key, 'savedAt': now.toIso8601String(),
      'items': [
        {'isFolder': true, 'name': 'Vehicle', 'pdfCount': -99, 'sizeBytes': -1},
        {'isFolder': false, 'name': 'Policy.pdf', 'sizeBytes': -100},
      ],
    }, key);
    expect(parsed, isNotNull);
    expect(parsed!.items.first.pdfCount, 0);
    expect(parsed.items.last.sizeBytes, 0);
  });
}
