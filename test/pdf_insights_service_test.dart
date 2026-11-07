import 'package:flutter_test/flutter_test.dart';
import 'package:docs_grid/features/documents/data/pdf_insights_service.dart';

void main() {
  group('PdfInsightsService suggestions', () {
    final service = PdfInsightsService();

    test('suggests a clean name from the first meaningful PDF text line', () {
      expect(
        service.suggestName(
          currentName: 'scan_001',
          text: '  Insurance Policy  \\nPolicy Number: 12345',
        ),
        'Insurance Policy',
      );
    });

    test('does not suggest the current name again', () {
      expect(
        service.suggestName(currentName: 'Insurance Policy', text: 'Insurance Policy\\nMore text'),
        isNull,
      );
    });

    test('suggests a category from local PDF text', () {
      expect(
        service.suggestCategory(fileName: 'scan.pdf', text: 'Motor insurance policy premium'),
        'Insurance',
      );
    });

    test('returns no category when there is no matching evidence', () {
      expect(
        service.suggestCategory(fileName: 'scan.pdf', text: 'Some unrelated words'),
        isNull,
      );
    });
  });
}
