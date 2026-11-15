import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/core/storage/portable_snapshot_scheduler.dart';
import 'package:docs_grid/features/documents/data/document_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const storageChannel = MethodChannel('docsgrid/storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const pdfName = 'RAS_Political_Science_Current_Affairs_2025_26_.pdf';
  const phoneUri = 'content://phone/RAS_Political_Science_Current_Affairs_2025_26_.pdf';

  late Directory temp;
  late Database db;
  late DocumentRepository repo;
  late Map<String, List<int>> sourceBytes;
  final pdfA = utf8.encode('%PDF-1.7\nDocsGrid recovered PDF A');
  final pdfB = utf8.encode('%PDF-1.7\nDocsGrid recovered PDF B');

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('docsgrid_duplicate_scope_');
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE documents (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        original_name TEXT,
        storage_uri TEXT,
        relative_path TEXT,
        mime_type TEXT,
        size_bytes INTEGER,
        sha256 TEXT,
        folder_id TEXT,
        extracted_text_status TEXT,
        created_at TEXT,
        updated_at TEXT,
        deleted_at TEXT,
        metadata_json TEXT,
        source TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE history (
        id TEXT PRIMARY KEY,
        document_id TEXT,
        action TEXT,
        details_json TEXT,
        created_at TEXT
      )
    ''');
    sourceBytes = {phoneUri: pdfA};
    messenger.setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method == 'getTemporaryDirectory') return temp.path;
      throw MissingPluginException('Unexpected path request: ${call.method}');
    });
    messenger.setMockMethodCallHandler(storageChannel, (call) async {
      if (call.method != 'copyPdfToPath') {
        throw MissingPluginException('Unexpected storage request: ${call.method}');
      }
      final source = (call.arguments as Map)['sourceUri'] as String;
      final destination = (call.arguments as Map)['destinationPath'] as String;
      final bytes = sourceBytes[source];
      if (bytes == null) throw StateError('Unknown source URI $source');
      await File(destination).writeAsBytes(bytes, flush: true);
      return true;
    });
    repo = DocumentRepository(database: AppDatabase.forTesting(() async => db));
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(storageChannel, null);
    await PortableSnapshotScheduler.instance.flushNow();
    await db.close();
    await temp.delete(recursive: true);
  });

  test('Phone PDF alone is not a Grid duplicate; first recovery registers it', () async {
    expect(await db.query('documents'), isEmpty);
    final restored = await repo.importExistingSharedPdf(
      storageUri: phoneUri,
      displayName: pdfName,
    );
    expect(restored, isTrue);
    final rows = await db.query('documents');
    expect(rows, hasLength(1));
    expect(rows.single['original_name'], pdfName);
    expect(rows.single['sha256'], sha256.convert(pdfA).toString());
    expect(rows.single['storage_uri'], phoneUri);
    expect(rows.single['source'], 'reinstall_recovery');
  });

  test('only a second matching active Grid SHA-256 record is duplicate', () async {
    final first = await repo.importExistingSharedPdf(
      storageUri: phoneUri, displayName: pdfName,
    );
    final repeated = await repo.importExistingSharedPdf(
      storageUri: phoneUri, displayName: pdfName,
    );
    expect(first, isTrue);
    expect(repeated, isFalse);
    expect(await db.query('documents'), hasLength(1));
  });

  test('same PDF filename but different content is not a duplicate', () async {
    const secondUri = 'content://phone/different-file-same-name';
    sourceBytes[secondUri] = pdfB;
    final first = await repo.importExistingSharedPdf(
      storageUri: phoneUri, displayName: pdfName,
    );
    final different = await repo.importExistingSharedPdf(
      storageUri: secondUri, displayName: pdfName,
    );
    expect(first, isTrue);
    expect(different, isTrue);
    final rows = await db.query('documents');
    expect(rows, hasLength(2));
    expect(rows.map((row) => row['sha256']).toSet(), hasLength(2));
  });
}
