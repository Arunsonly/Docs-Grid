import 'package:docs_grid/features/tools/document_tools_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('portable recovery folder path normalization', () {
    test('matches UI breadcrumbs to storage-relative paths', () {
      expect(
        DocumentToolsService.normalizeRecoveryFolderPath('Parent / Child'),
        'Parent/Child',
      );
    });

    test('normalizes nested paths and preserves spaces inside names', () {
      expect(
        DocumentToolsService.normalizeRecoveryFolderPath(
          'Tax Records / FY 2026 / Motor Policy',
        ),
        'Tax Records/FY 2026/Motor Policy',
      );
    });

    test('keeps already-normalized paths stable', () {
      expect(
        DocumentToolsService.normalizeRecoveryFolderPath('Parent/Child'),
        'Parent/Child',
      );
    });

    test('returns an empty path for empty or separator-only input', () {
      expect(DocumentToolsService.normalizeRecoveryFolderPath(''), '');
      expect(DocumentToolsService.normalizeRecoveryFolderPath(' / / '), '');
    });
  });
}
