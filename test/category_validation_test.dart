import 'package:docs_grid/features/categories/data/category_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CategoryRepository.validateName', () {
    test('trims valid names', () {
      expect(CategoryRepository.validateName('  Insurance  '), 'Insurance');
    });

    test('rejects empty names', () {
      expect(() => CategoryRepository.validateName('  '), throwsArgumentError);
    });

    test('rejects names longer than forty characters', () {
      expect(() => CategoryRepository.validateName(List.filled(41, 'x').join()), throwsArgumentError);
    });

    test('accepts the forty character boundary', () {
      expect(CategoryRepository.validateName(List.filled(40, 'x').join()), List.filled(40, 'x').join());
    });
  });
}
