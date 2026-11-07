import 'package:flutter_test/flutter_test.dart';
import 'package:docs_grid/main.dart';

void main() {
  testWidgets('DocsGrid home screen renders', (tester) async {
    await tester.pumpWidget(const DocsGridApp());

    expect(find.text('DocsGrid'), findsOneWidget);
    expect(find.text('Your documents, organised.'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Folders'), findsWidgets);
  });
}
