import 'package:docs_grid/features/tools/document_crop_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('crop screen keeps the page filmstrip visible while cropping', (tester) async {
    const onePixelPng = <int>[
      137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
      0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137,
      0, 0, 0, 11, 73, 68, 65, 84, 120, 156, 99, 96, 0, 2, 0, 0, 5, 0, 1,
      167, 69, 39, 154, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
    ];
    final reordered = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: DocumentCropScreen(
        imageBytes: Uint8List.fromList(onePixelPng),
        pagePaths: const ['/tmp/page-1.jpg', '/tmp/page-2.jpg'],
        onReorderPages: (paths) => reordered
          ..clear()
          ..addAll(paths),
      ),
    ));
    await tester.pump();
    expect(find.byKey(const ValueKey('crop-page-filmstrip')), findsOneWidget);
    expect(find.text('Pages · drag to reorder'), findsOneWidget);
    expect(find.byKey(const ValueKey('crop-page-/tmp/page-1.jpg')), findsOneWidget);
    expect(find.byKey(const ValueKey('crop-page-/tmp/page-2.jpg')), findsOneWidget);
    expect(reordered, isEmpty);
  });
}
