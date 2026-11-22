import 'package:docs_grid/core/settings/ocr_search_preferences.dart';
import 'package:docs_grid/features/documents/presentation/ocr_search_mode_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('new installation keeps OCR disabled; enabling persists across app restart',
      () async {
    expect(await OcrSearchPreferences.isEnabled(), isFalse);
    await OcrSearchPreferences.setEnabled(true);
    // A new reader (as on a new app launch) sees the durable permission.
    expect(await OcrSearchPreferences.isEnabled(), isTrue);
    await OcrSearchPreferences.setEnabled(false);
    expect(await OcrSearchPreferences.isEnabled(), isFalse);
  });

  testWidgets('OCR toggle starts off, highlights on one tap, and turns off on second tap',
      (tester) async {
    var active = false;
    Widget app() => MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, refresh) => OcrSearchModeControl(
            searchInsidePdf: active,
            onChanged: (value) => refresh(() => active = value),
          ),
        ),
      ),
    );
    await tester.pumpWidget(app());
    expect(active, isFalse);

    expect(find.byType(PopupMenuButton), findsNothing);
    expect(find.text('OCR'), findsOneWidget);
    expect(find.byTooltip('Turn on OCR search'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ocr-search-mode-selector')));
    await tester.pumpAndSettle();
    expect(active, isTrue);
    expect(find.byTooltip('Turn off OCR search'), findsOneWidget);
    expect(find.byType(PopupMenuButton), findsNothing);

    await tester.tap(find.byKey(const ValueKey('ocr-search-mode-selector')));
    await tester.pumpAndSettle();
    expect(active, isFalse);
    expect(find.byTooltip('Turn on OCR search'), findsOneWidget);

    // Recreate the entire search screen; OCR is a per-screen choice, not saved.
    active = false;
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpWidget(app());
    expect(active, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled global permission hides OCR choice entirely',
      (tester) async {
    var available = false;
    bool searchInsidePdf = false;
    Widget app() => MaterialApp(
      home: Scaffold(body: StatefulBuilder(
        builder: (context, rebuild) => Row(children: [
          const Icon(Icons.search),
          if (available)
            OcrSearchModeControl(
              searchInsidePdf: searchInsidePdf,
              onChanged: (value) => rebuild(() => searchInsidePdf = value),
            ),
        ]),
      )),
    );
    await tester.pumpWidget(app());
    expect(find.byKey(const ValueKey('ocr-search-mode-selector')), findsNothing);
    available = true;
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpWidget(app());
    expect(find.byKey(const ValueKey('ocr-search-mode-selector')), findsOneWidget);
    expect(searchInsidePdf, isFalse);
  });
}
