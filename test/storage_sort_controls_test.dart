import 'package:docs_grid/core/widgets/storage_sort_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Name sorting is case-insensitive in both directions', () {
    expect(compareStorageItems(
      nameA: 'alpha.pdf', nameB: 'Zulu.pdf',
      field: StorageSortField.name, ascending: true,
    ), lessThan(0));
    expect(compareStorageItems(
      nameA: 'alpha.pdf', nameB: 'Zulu.pdf',
      field: StorageSortField.name, ascending: false,
    ), greaterThan(0));
  });

  test('Date sorts by actual timestamps regardless of document name', () {
    final older = DateTime.utc(2025, 1, 1);
    final newer = DateTime.utc(2026, 11, 17);
    expect(compareStorageItems(
      nameA: 'Z-last.pdf', nameB: 'A-first.pdf',
      dateA: older, dateB: newer,
      field: StorageSortField.date, ascending: true,
    ), lessThan(0));
    expect(compareStorageItems(
      nameA: 'Z-last.pdf', nameB: 'A-first.pdf',
      dateA: older, dateB: newer,
      field: StorageSortField.date, ascending: false,
    ), greaterThan(0));
  });

  test('Unknown date always goes last, with stable name ties', () {
    final date = DateTime.utc(2026, 11, 17);
    for (final ascending in [true, false]) {
      expect(compareStorageItems(
        nameA: 'Unknown', nameB: 'Known',
        dateB: date, field: StorageSortField.date, ascending: ascending,
      ), greaterThan(0));
      expect(compareStorageItems(
        nameA: 'Known', nameB: 'Unknown',
        dateA: date, field: StorageSortField.date, ascending: ascending,
      ), lessThan(0));
    }
  });

  testWidgets('filter menu selects Name/Date and arrow independently toggles order',
      (tester) async {
    var field = StorageSortField.name;
    var ascending = true;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          return StorageSortControls(
            field: field,
            ascending: ascending,
            onFieldChanged: (value) => setState(() => field = value),
            onAscendingChanged: (value) => setState(() => ascending = value),
          );
        }),
      ),
    ));

    expect(find.byKey(const ValueKey('storage-sort-filter')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-sort-direction')), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('storage-sort-filter')));
    await tester.pumpAndSettle();
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Date'), findsOneWidget);
    await tester.tap(find.text('Date'));
    await tester.pumpAndSettle();
    expect(field, StorageSortField.date);
    await tester.tap(find.byKey(const ValueKey('storage-sort-direction')));
    await tester.pumpAndSettle();
    expect(ascending, isFalse);
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('storage-sort-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name'));
    await tester.pumpAndSettle();
    expect(field, StorageSortField.name);
    expect(ascending, isFalse,
        reason: 'Changing the field must not silently reset direction.');
  });
}
