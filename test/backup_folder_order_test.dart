import 'package:docs_grid/features/tools/backup_folder_graph_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('folder insert order places every parent before its child', () {
    final unordered = <Map<String, Object?>>[
      {'id': 'leaf', 'parent_id': 'child'},
      {'id': 'root', 'parent_id': null},
      {'id': 'child', 'parent_id': 'root'},
    ];
    final ordered = BackupFolderGraphValidator.parentFirst(unordered);
    final positions = {
      for (var i = 0; i < ordered.length; i++) ordered[i]['id']: i,
    };
    expect(positions['root']!, lessThan(positions['child']!));
    expect(positions['child']!, lessThan(positions['leaf']!));
  });

  test('folder delete order places every child before its parent', () {
    final unordered = <Map<String, Object?>>[
      {'id': 'leaf', 'parent_id': 'child'},
      {'id': 'root', 'parent_id': null},
      {'id': 'child', 'parent_id': 'root'},
    ];
    final ordered = BackupFolderGraphValidator.childFirst(unordered);
    final positions = {
      for (var i = 0; i < ordered.length; i++) ordered[i]['id']: i,
    };
    expect(positions['leaf']!, lessThan(positions['child']!));
    expect(positions['child']!, lessThan(positions['root']!));
  });
}
