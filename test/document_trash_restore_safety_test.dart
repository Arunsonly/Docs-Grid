import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/documents/data/document_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() { sqfliteFfiInit(); databaseFactory = databaseFactoryFfi; });

  Future<Database> db() =>
      AppDatabase.instance.openProductionSchemaForTesting(inMemoryDatabasePath);

  Future<void> addTrash(Database database, String id, String uri, String? digest) =>
      database.insert('documents', {
        'id': id, 'name': 'Archived.pdf', 'storage_uri': uri,
        'mime_type': 'application/pdf', 'size_bytes': 4, 'sha256': digest,
        'created_at': '2026-11-18T00:00:00Z',
        'updated_at': '2026-11-18T00:00:00Z',
        'deleted_at': '2026-11-18T00:00:00Z',
      }).then((_) {});

  test('missing PDF remains in Recycle Bin', () async {
    final database = await db();
    addTearDown(database.close);
    final missing = '${Directory.systemTemp.path}/absent-${DateTime.now().microsecondsSinceEpoch}.pdf';
    await addTrash(database, 'missing', missing, null);
    final repo = DocumentRepository(database: AppDatabase.forTesting(() async => database));
    await expectLater(repo.restoreFromTrash((await repo.listTrash()).single), throwsStateError);
    expect((await database.query('documents', where: 'id = ?', whereArgs: ['missing']))
        .single['deleted_at'], isNotNull);
  });

  test('changed PDF with known checksum cannot be restored', () async {
    final database = await db();
    addTearDown(database.close);
    final dir = await Directory.systemTemp.createTemp('docsgrid-restore-');
    addTearDown(() async { if (await dir.exists()) await dir.delete(recursive: true); });
    final file = File('${dir.path}/different.pdf');
    await file.writeAsBytes([1, 2, 3, 4]);
    await addTrash(database, 'different', file.path,
        sha256.convert([5, 6, 7, 8]).toString());
    final repo = DocumentRepository(database: AppDatabase.forTesting(() async => database));
    await expectLater(repo.restoreFromTrash((await repo.listTrash()).single), throwsStateError);
    expect((await database.query('documents', where: 'id = ?', whereArgs: ['different']))
        .single['deleted_at'], isNotNull);
    expect(await file.exists(), isTrue);
  });
}
