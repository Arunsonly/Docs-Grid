import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/tools/document_tools_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database database;
  late Directory directory;
  late DocumentToolsService service;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('docsgrid-duplicate-hash-');
    database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE documents (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              storage_uri TEXT,
              sha256 TEXT,
              deleted_at TEXT,
              created_at TEXT,
              updated_at TEXT
            )
          ''');
        },
      ),
    );
    service = DocumentToolsService(database: AppDatabase.forTesting(() async => database));
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test('exact duplicate groups are based on current file bytes, not stale hashes', () async {
    final first = File('${directory.path}/first.pdf');
    final second = File('${directory.path}/second.pdf');
    final third = File('${directory.path}/third.pdf');
    await first.writeAsString('%PDF-1.4\nidentical\n%%EOF');
    await second.writeAsString('%PDF-1.4\nidentical\n%%EOF');
    await third.writeAsString('%PDF-1.4\ndifferent\n%%EOF');

    for (final row in [
      {'id': 'doc-1', 'name': 'First', 'storage_uri': first.path},
      {'id': 'doc-2', 'name': 'Second', 'storage_uri': second.path},
      {'id': 'doc-3', 'name': 'Third', 'storage_uri': third.path},
    ]) {
      await database.insert('documents', {
        ...row,
        'sha256': 'stale-hash',
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    }

    final groups = await service.findExactDuplicates();
    expect(groups, hasLength(1));
    expect(groups.single['copies'], 2);
    expect((groups.single['document_ids'] as String).split(',').toSet(), {'doc-1', 'doc-2'});

    final saved = await database.query('documents', columns: ['id', 'sha256']);
    final expectedDigest = sha256.convert(await first.readAsBytes()).toString();
    expect(saved.firstWhere((row) => row['id'] == 'doc-1')['sha256'], expectedDigest);
    expect(saved.firstWhere((row) => row['id'] == 'doc-3')['sha256'], isNot('stale-hash'));
  });
}
