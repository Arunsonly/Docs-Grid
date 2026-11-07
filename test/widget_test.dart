import 'package:docs_grid/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('DocsGrid document library shell renders', (tester) async {
    await tester.pumpWidget(const DocsGridApp());

    expect(find.text('DocsGrid · My Documents'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Folders'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('Recently opened screen is reachable from Settings', (tester) async {
    await tester.pumpWidget(const DocsGridApp());
    await tester.tap(find.text('Settings'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Recently opened'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Recently opened'), findsOneWidget);
    expect(find.text('Open a PDF and it will appear here.'), findsOneWidget);
  });
}
