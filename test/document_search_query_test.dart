import 'package:docs_grid/features/documents/data/document_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Document search LIKE escaping', () {
    test('escapes percent and underscore as literal characters', () {
      expect(
        escapeLikeWildcards('Policy_50%'),
        r'Policy\_50\%',
      );
    });

    test('escapes literal backslashes', () {
      expect(
        escapeLikeWildcards('Policy\\50%'),
        'Policy\\\\50\\%',
      );
    });
    test('leaves ordinary search text unchanged', () {
      expect(escapeLikeWildcards('Policy 2026'), 'Policy 2026');
    });
  });
}
