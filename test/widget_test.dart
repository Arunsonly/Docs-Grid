import 'package:docs_grid/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('DocsGrid Dashboard home scaffold renders', (tester) async {
    await tester.pumpWidget(const DocsGridApp());

    expect(find.text('DocsGrid'), findsOneWidget);
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Folders'), findsWidgets);
    expect(find.text('Star'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

}
