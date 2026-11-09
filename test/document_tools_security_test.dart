import 'package:docs_grid/features/tools/document_tools_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Backup restore path tokens', () {
    test('never embeds raw path separators from untrusted IDs', () {
      final token = DocumentToolsService.safeRestorePathToken('../../outside');
      expect(token, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(token, isNot(contains('/')));
      expect(token, isNot(contains(r'\\')));
    });

    test('is deterministic for the same source ID', () {
      expect(
        DocumentToolsService.safeRestorePathToken('folder-123'),
        DocumentToolsService.safeRestorePathToken('folder-123'),
      );
    });

    test('different IDs map to distinct path tokens in representative cases', () {
      expect(
        DocumentToolsService.safeRestorePathToken('folder-123'),
        isNot(DocumentToolsService.safeRestorePathToken('folder-124')),
      );
    });

    test('OCR search escapes SQL LIKE wildcards and backslashes', () {
      final slash = String.fromCharCode(92);
      expect(
        DocumentToolsService.escapeLikeQuery('a%b_c${slash}d'),
        ['a', slash, '%b', slash, '_c', slash, slash, 'd'].join(),
      );
    });

    test('OCR search leaves ordinary text unchanged', () {
      expect(DocumentToolsService.escapeLikeQuery('Policy 2026'), 'Policy 2026');
    });
  });
}
