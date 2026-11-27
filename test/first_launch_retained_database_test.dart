import 'dart:io';

import 'package:docs_grid/core/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory dir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    dir = Directory.systemTemp.createTempSync('docsgrid_retained_db_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('first-launch check distinguishes an empty installation from retained data',
      () async {
    final producer = AppDatabase.forTesting(
        () => throw StateError('Not used by production-schema fixture'));
    final db = await producer.openProductionSchemaForTesting(
        '${dir.path}/kept_docs_grid.db');
    final retained = AppDatabase.forTesting(() async => db);
    try {
      // A new install may have built-in categories; these are not user data.
      expect(await retained.hasPortableUserData(), isFalse);

      // Reinstall with Android Keep App Data retains meaningful SQLite rows.
      // The first-launch flow should skip the unsolicited restore prompt.
      await db.insert('documents', {
        'id': 'kept-document-1',
        'name': 'kept-document',
        'created_at': '2026-11-23T01:00:00Z',
        'updated_at': '2026-11-23T01:00:00Z',
      });
      expect(await retained.hasPortableUserData(), isTrue);

      // The read-only detection must not modify the retained document.
      final rows = await db.query('documents',
          where: 'id = ?', whereArgs: ['kept-document-1']);
      expect(rows, hasLength(1));
      expect(rows.single['name'], 'kept-document');
    } finally {
      await db.close();
    }
  });

  test('user-created folder is retained data even without PDFs', () async {
    final producer = AppDatabase.forTesting(
        () => throw StateError('Not used by production-schema fixture'));
    final db = await producer.openProductionSchemaForTesting(
        '${dir.path}/kept_folder.db');
    final retained = AppDatabase.forTesting(() async => db);
    try {
      expect(await retained.hasPortableUserData(), isFalse);
      await db.insert('folders', {
        'id': 'kept-folder-1',
        'name': 'Important documents',
        'created_at': '2026-11-23T01:00:00Z',
        'updated_at': '2026-11-23T01:00:00Z',
      });
      expect(await retained.hasPortableUserData(), isTrue);
    } finally {
      await db.close();
    }
  });

  test('an empty restored database still allows old-source discovery', () async {
    final producer = AppDatabase.forTesting(
        () => throw StateError('Not used by production-schema fixture'));
    final db = await producer.openProductionSchemaForTesting(
        '${dir.path}/empty_database.db');
    try {
      final retained = AppDatabase.forTesting(() async => db);
      expect(await retained.hasPortableUserData(), isFalse);
    } finally {
      await db.close();
    }
  });
}
