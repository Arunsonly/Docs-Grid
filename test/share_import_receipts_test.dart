import 'dart:convert';

import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/documents/data/share_import_receipts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<Database> realDatabase() =>
      AppDatabase.instance.openProductionSchemaForTesting(inMemoryDatabasePath);

  test('same bytes from independent share jobs are not one logical PDF',
      () async {
    final db = await realDatabase();
    addTearDown(db.close);
    const first = '83e269b1-10a1-435c-81b6-111111111111';
    const second = '83e269b1-10a1-435c-81b6-222222222222';
    const digest = '1234567890abcdef';
    await db.insert('documents', {
      'id': 'first-import',
      'name': 'A.pdf',
      'mime_type': 'application/pdf',
      'size_bytes': 1,
      'sha256': digest,
      'created_at': '2026-11-18T00:00:00Z',
      'updated_at': '2026-11-18T00:00:00Z',
      'metadata_json': jsonEncode({'shareImportId': first}),
      'source': 'share',
    });
    expect(await ShareImportReceipts.isCommitted(
        db, id: first, sha256: digest), isTrue);
    expect(await ShareImportReceipts.isCommitted(
        db, id: second, sha256: digest), isFalse);
  });

  test('a reused share job with altered bytes is blocked', () async {
    final db = await realDatabase();
    addTearDown(db.close);
    const id = '83e269b1-10a1-435c-81b6-333333333333';
    await db.insert('documents', {
      'id': 'committed',
      'name': 'PDF',
      'mime_type': 'application/pdf',
      'created_at': '2026-11-18T00:00:00Z',
      'updated_at': '2026-11-18T00:00:00Z',
      'sha256': 'aaaa',
      'source': 'share',
      'metadata_json': jsonEncode({'shareImportId': id}),
    });
    await expectLater(ShareImportReceipts.isCommitted(
        db, id: id, sha256: 'bbbb'), throwsStateError);
  });

  test('a malformed job ID cannot match a receipt', () async {
    final db = await realDatabase();
    addTearDown(db.close);
    await expectLater(
      ShareImportReceipts.isCommitted(db, id: 'unsafe-id', sha256: '0000'),
      throwsArgumentError,
    );
  });
}
