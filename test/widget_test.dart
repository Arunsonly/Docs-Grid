import 'dart:ui' show Size;

import 'package:docs_grid/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('DocsGrid Dashboard home scaffold renders', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const DocsGridApp());

    expect(find.text('DocsGrid'), findsOneWidget);
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Grid'), findsOneWidget);
    expect(find.text('Star'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

}
