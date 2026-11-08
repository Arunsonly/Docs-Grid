import 'dart:async';

import 'package:docs_grid/core/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

class _FakeDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('concurrent first access shares one database-open operation', () async {
    final completer = Completer<Database>();
    final fake = _FakeDatabase();
    var openCount = 0;
    final database = AppDatabase.forTesting(() {
      openCount++;
      return completer.future;
    });

    final first = database.database;
    final second = database.database;
    expect(openCount, 1);

    completer.complete(fake);
    expect(identical(await first, fake), isTrue);
    expect(identical(await second, fake), isTrue);
    expect(openCount, 1);
  });

  test('failed first open can be retried', () async {
    final fake = _FakeDatabase();
    var openCount = 0;
    final database = AppDatabase.forTesting(() async {
      openCount++;
      if (openCount == 1) throw StateError('temporary open failure');
      return fake;
    });

    await expectLater(database.database, throwsStateError);
    expect(identical(await database.database, fake), isTrue);
    expect(openCount, 2);
  });
}
