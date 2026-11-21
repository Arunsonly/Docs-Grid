import 'package:docs_grid/main.dart';
import 'package:docs_grid/features/documents/presentation/documents_screen.dart';
import 'package:docs_grid/features/folders/presentation/folders_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _IdentityProbe extends StatefulWidget {
  const _IdentityProbe({super.key, required this.onCreate});
  final ValueChanged<int> onCreate;

  @override
  State<_IdentityProbe> createState() => _IdentityProbeState();
}

class _IdentityProbeState extends State<_IdentityProbe> {
  static int sequence = 0;
  late final int identity = ++sequence;

  @override
  void initState() {
    super.initState();
    widget.onCreate(identity);
  }

  @override
  Widget build(BuildContext context) => Text('state-$identity');
}

void main() {
  test('Phone, Home and Grid use correct real screen types and distinct state keys', () {
    final phone = DocsGridHome.screenForTab(0) as DocumentsScreen;
    final home = DocsGridHome.screenForTab(1) as DocumentsScreen;
    final grid = DocsGridHome.screenForTab(2);
    expect(phone.phoneOnly, isTrue);
    expect(home.phoneOnly, isFalse);
    expect(home.favoritesOnly, isFalse);
    expect(home.recentOnly, isFalse);
    expect(grid, isA<FoldersScreen>());
    expect(phone.key, isNotNull);
    expect(home.key, isNotNull);
    expect(home.key, isNot(phone.key));
  });

  testWidgets('Grid > Phone > Home and Home > Phone > Home NEVER reuse Phone State',
      (tester) async {
    final created = <int>[];
    Future<int> showTab(int index) async {
      final widget = DocsGridHome.screenForTab(index);
      // A State probe with the production screen KEY exercises Flutter
      // Element.canUpdate without invoking real OS storage during this test.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: _IdentityProbe(
          key: widget.key,
          onCreate: created.add,
        )),
      ));
      return created.last;
    }

    final originalHome = await showTab(1);
    final grid = await showTab(2);
    final phone = await showTab(0);
    final homeAfterPhone = await showTab(1);
    expect({originalHome, grid, phone, homeAfterPhone}.length, 4,
        reason: 'The Phone State must not be reused to render Home');
    final phoneAgain = await showTab(0);
    final homeAgain = await showTab(1);
    expect(phoneAgain, isNot(homeAgain));
    expect(created, hasLength(6));
  });
}
