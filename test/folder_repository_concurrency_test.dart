import 'dart:async';

import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

class _ConcurrentFolderDatabase implements Database {
  final folders = <Map<String, Object?>>[];
  Future<void> _tail = Future<void>.value();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #query) {
      // Both callers may pass the non-transactional preflight check.
      return Future<List<Map<String, Object?>>>.value([]);
    }
    if (invocation.memberName == #transaction) {
      final callback = invocation.positionalArguments.first as Function;
      final completer = Completer<void>();
      final previous = _tail;
      _tail = completer.future;
      return () async {
        await previous;
        try {
          return await callback(_ConcurrentFolderTransaction(folders));
        } finally {
          completer.complete();
        }
      }();
    }
    return super.noSuchMethod(invocation);
  }
}

class _ConcurrentFolderTransaction implements Transaction {
  _ConcurrentFolderTransaction(this.folders);
  final List<Map<String, Object?>> folders;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #query) {
      final where = invocation.namedArguments[#where] as String? ?? '';
      if (where.contains('parent_id IS ?') && where.contains('name = ?')) {
        final args = invocation.namedArguments[#whereArgs] as List<Object?>;
        final parentId = args[0];
        final name = args[1] as String;
        return Future<List<Map<String, Object?>>>.value(
          folders.where((row) =>
            row['parent_id'] == parentId &&
            (row['name'] as String).toLowerCase() == name.toLowerCase() &&
            row['deleted_at'] == null,
          ).toList(),
        );
      }
      return Future<List<Map<String, Object?>>>.value([]);
    }
    if (invocation.memberName == #insert) {
      final values = Map<String, Object?>.from(
        invocation.positionalArguments[1] as Map,
      );
      folders.add(values);
      return Future<int>.value(1);
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('concurrent creates cannot commit duplicate sibling folder names', () async {
    final db = _ConcurrentFolderDatabase();
    final repository = FolderRepository(
      database: AppDatabase.forTesting(() async => db),
    );

    final results = await Future.wait([
      repository.create(name: 'Policies'),
      repository.create(name: 'policies'),
    ].map((future) async {
      try {
        await future;
        return 'created';
      } on StateError {
        return 'rejected';
      }
    }));

    expect(results.where((result) => result == 'created'), hasLength(1));
    expect(results.where((result) => result == 'rejected'), hasLength(1));
    expect(db.folders, hasLength(1));
    expect(db.folders.single['name'], anyOf('Policies', 'policies'));
  });
}
