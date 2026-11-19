import 'dart:ui' show Size;

import 'package:docs_grid/main.dart';
import 'package:docs_grid/features/folders/presentation/folders_screen.dart';
import 'package:docs_grid/features/documents/presentation/phone_storage_browser_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('DocsGrid Dashboard home scaffold renders', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const DocsGridApp());

    expect(find.text('DocsGrid'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Grid'), findsAtLeastNWidgets(1));
    expect(find.text('Phone'), findsAtLeastNWidgets(1));
  });

  testWidgets('Grid opens with a Material ancestor for its InkWell controls',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const DocsGridApp());
    await tester.tap(find.text('Grid').last);
    await tester.pump();

    expect(find.byType(FoldersScreen), findsOneWidget);
    final folderInkWells = find.descendant(
      of: find.byType(FoldersScreen),
      matching: find.byType(InkWell),
    );
    expect(folderInkWells, findsWidgets);
    // Reproduces the reported red-screen failure when Grid lacks Material.
    expect(() => Material.of(tester.element(folderInkWells.first)),
        returnsNormally);
    // A transparent Material resolves ink widgets but recreates the black
    // background/black text shown on the affected device. Check the actual
    // filled Grid surface, not merely the existence of a Material ancestor.
    final expectedSurface = Theme.of(
      tester.element(find.byType(FoldersScreen)),
    ).scaffoldBackgroundColor;
    final gridMaterials = tester.widgetList<Material>(find.descendant(
      of: find.byType(FoldersScreen),
      matching: find.byType(Material),
    ));
    expect(gridMaterials.any((material) =>
        material.type == MaterialType.canvas &&
        material.color == expectedSurface), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Phone and Grid tab states survive Home navigation',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const DocsGridApp());
    await tester.tap(find.text('Grid').last);
    await tester.pump();
    final gridState = tester.state(find.byType(FoldersScreen));

    await tester.tap(find.text('Phone').last);
    await tester.pump();
    final phoneState = tester.state(find.byType(PhoneStorageBrowserScreen));
    // Inactive tabs are offstage, not disposed or rescanned on every switch.
    expect(find.byType(FoldersScreen, skipOffstage: false), findsOneWidget);

    await tester.tap(find.text('Home').last);
    await tester.pump();
    await tester.tap(find.text('Grid').last);
    await tester.pump();
    expect(tester.state(find.byType(FoldersScreen)), same(gridState));

    await tester.tap(find.text('Phone').last);
    await tester.pump();
    expect(tester.state(find.byType(PhoneStorageBrowserScreen)),
        same(phoneState));
    expect(tester.takeException(), isNull);
  });

}
