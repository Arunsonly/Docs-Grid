import 'dart:async';

import 'package:docs_grid/features/tools/document_tools_screen.dart';
import 'package:docs_grid/features/tools/document_tools_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _DelayedSearchService extends DocumentToolsService {
  final Completer<List<Map<String, Object?>>> completer =
      Completer<List<Map<String, Object?>>>();
  int calls = 0;

  @override
  Future<List<Map<String, Object?>>> searchText(String query) {
    calls++;
    return completer.future;
  }
}

void main() {
  testWidgets('OCR search ignores completion after its route is disposed',
      (tester) async {
    final service = _DelayedSearchService();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: DocumentToolsScreen(service: service)),
    ));

    await tester.enterText(find.byType(TextField).first, 'policy');
    await tester.tap(find.byKey(const ValueKey('ocr-search-button')));
    await tester.pump();

    expect(service.calls, 1);

    // Simulate leaving the tools screen while the database query is pending.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    service.completer.complete([
      <String, Object?>{
        'id': 'doc-1',
        'name': 'Policy',
        'storage_uri': '/tmp/policy.pdf',
        'extracted_text': 'policy',
        'match_position': 1,
        'match_page': 1,
      },
    ]);
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('OCR search prevents duplicate concurrent submissions',
      (tester) async {
    final service = _DelayedSearchService();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: DocumentToolsScreen(service: service)),
    ));
    await tester.enterText(find.byType(TextField).first, 'policy');

    await tester.tap(find.byKey(const ValueKey('ocr-search-button')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ocr-search-button')));
    await tester.pump();

    expect(service.calls, 1);
    service.completer.complete(const []);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
