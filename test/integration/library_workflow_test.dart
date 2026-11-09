import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/tools/document_tools_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database database;
  late Directory directory;
  late DocumentToolsService tools;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('docsgrid-e2e-');
    database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE documents (
              id TEXT PRIMARY KEY, name TEXT NOT NULL, storage_uri TEXT,
              sha256 TEXT, deleted_at TEXT, created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL, extracted_text_status TEXT
            )
          ''');
          await db.execute('''
            CREATE TABLE document_text_index (
              document_id TEXT PRIMARY KEY, extracted_text TEXT NOT NULL,
              indexed_at TEXT, page_count INTEGER
            )
          ''');
        },
      ),
    );
    tools = DocumentToolsService(
      database: AppDatabase.forTesting(() async => database),
    );
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test('PDF library workflow: index -> OCR search -> duplicate review', () async {
    const stamp = '2026-11-09T00:00:00.000Z';
    final bytes = '%PDF-1.4\nPolicy number 987654321\n%%EOF';
    final digest = sha256.convert(bytes.codeUnits).toString();
    final first = File('${directory.path}/policy-a.pdf');
    final second = File('${directory.path}/policy-b.pdf');
    await first.writeAsString(bytes);
    await second.writeAsString(bytes);

    for (final item in [
      {'id': 'a', 'name': 'Policy A', 'path': first.path},
      {'id': 'b', 'name': 'Policy B', 'path': second.path},
    ]) {
      await database.insert('documents', {
        'id': item['id'], 'name': item['name'], 'storage_uri': item['path'],
        'sha256': digest, 'created_at': stamp, 'updated_at': stamp,
        'extracted_text_status': 'indexed',
      });
      await database.insert('document_text_index', {
        'document_id': item['id'],
        'extracted_text': '--- Page 1 ---\nPolicy number 987654321\nRenewal date 2027-01-01\nInsured person and address details are included for the policy holder and the annual premium payment record.',
        'indexed_at': stamp, 'page_count': 1,
      });
    }

    final search = await tools.searchText('987654321');
    expect(search.map((row) => row['id']).toSet(), {'a', 'b'});
    expect(search.every((row) => row['match_page'] == 1), isTrue);

    final duplicateGroups = await tools.findDuplicateGroups();
    expect(duplicateGroups, isNotEmpty);
    expect(duplicateGroups.any((group) =>
      group['duplicate_type'] == 'SHA-256' && group['copies'] == 2), isTrue);
    expect(duplicateGroups.any((group) =>
      group['duplicate_type'] == 'OCR text' && group['copies'] == 2), isTrue);

    // Soft-deleted items must disappear from search and duplicate results.
    await database.update('documents', {'deleted_at': stamp},
      where: 'id = ?', whereArgs: ['b']);
    expect((await tools.searchText('987654321')).map((r) => r['id']), ['a']);
    final afterDelete = await tools.findDuplicateGroups();
    expect(afterDelete.every((group) => group['copies'] == 1), isTrue);
  });
}
