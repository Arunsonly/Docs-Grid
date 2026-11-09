import 'dart:async';

import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

class _OrderDatabase implements Database {
  final rows = <Map<String, Object?>>[
    {'id': 'a', 'parent_id': null, 'deleted_at': null, 'sort_order': 0},
    {'id': 'b', 'parent_id': null, 'deleted_at': null, 'sort_order': 1},
    {'id': 'child', 'parent_id': 'a', 'deleted_at': null, 'sort_order': 0},
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #transaction) {
      final callback = invocation.positionalArguments.first as Function;
      return Future<Object?>(() => callback(_OrderTransaction(rows)));
    }
    return super.noSuchMethod(invocation);
  }
}

class _OrderTransaction implements Transaction {
  _OrderTransaction(this.rows);
  final List<Map<String, Object?>> rows;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #query) {
      final where = invocation.namedArguments[#where] as String;
      final args = invocation.namedArguments[#whereArgs] as List<Object?>?;
      final parentId = args?.isNotEmpty == true ? args!.first : null;
      return Future<List<Map<String, Object?>>>.value(rows.where((row) {
        if (row['deleted_at'] != null) return false;
        return where.contains('parent_id IS NULL')
            ? row['parent_id'] == null
            : row['parent_id'] == parentId;
      }).map((row) => Map<String, Object?>.from(row)).toList());
    }
    if (invocation.memberName == #batch) return _OrderBatch(rows);
    return super.noSuchMethod(invocation);
  }
}

class _OrderBatch implements Batch {
  _OrderBatch(this.rows);
  final List<Map<String, Object?>> rows;
  final List<({String id, int order})> updates = [];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #update) {
      final values = invocation.positionalArguments[1] as Map;
      final whereArgs = invocation.namedArguments[#whereArgs] as List<Object?>;
      updates.add((id: whereArgs.first as String, order: values['sort_order'] as int));
      return this;
    }
    if (invocation.memberName == #commit) {
      for (final update in updates) {
        final row = rows.firstWhere((row) => row['id'] == update.id);
        row['sort_order'] = update.order;
      }
      return Future<List<Object?>>.value([]);
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reorderChildren persists a complete sibling order only within its parent', () async {
    final db = _OrderDatabase();
    final repository = FolderRepository(
      database: AppDatabase.forTesting(() async => db),
    );

    await repository.reorderChildren(null, ['b', 'a']);

    expect(db.rows.firstWhere((row) => row['id'] == 'b')['sort_order'], 0);
    expect(db.rows.firstWhere((row) => row['id'] == 'a')['sort_order'], 1);
    expect(db.rows.firstWhere((row) => row['id'] == 'child')['sort_order'], 0);
  });

  test('reorderChildren rejects incomplete or duplicate sibling IDs', () async {
    final repository = FolderRepository(
      database: AppDatabase.forTesting(() async => _OrderDatabase()),
    );

    await expectLater(
      repository.reorderChildren(null, ['a']),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      repository.reorderChildren(null, ['a', 'a']),
      throwsA(isA<StateError>()),
    );
  });
}
