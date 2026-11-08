import 'package:docs_grid/features/tools/document_tools_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OCR duplicate text normalization', () {
    test('ignores page markers, case, punctuation and repeated whitespace', () {
      final first = DocumentToolsService.normalizeDuplicateText(
        '''
--- Page 1 ---
The QUICK, brown fox!
--- Page 2 --- jumps over the dog.
        ''',
      );
      final second = DocumentToolsService.normalizeDuplicateText(
        'the quick brown fox jumps over the dog',
      );

      expect(first, second);
    });

    test('preserves Devanagari letters and normalizes mixed Hindi-English text', () {
      final first = DocumentToolsService.normalizeDuplicateText(
        '''
--- Page 1 ---
नमस्ते दुनिया! DocsGrid 2026
        ''',
      );
      final second = DocumentToolsService.normalizeDuplicateText(
        'नमस्ते-दुनिया DocsGrid 2026',
      );

      expect(first, second);
      expect(first, contains('नमस्ते'));
      expect(first, contains('दुनिया'));
    });
  });
}
