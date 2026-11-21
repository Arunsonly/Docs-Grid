import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/documents/data/document_repository.dart';
import 'package:docs_grid/features/documents/data/home_dashboard_cache.dart';
import 'package:docs_grid/features/documents/data/phone_recent_history.dart';
import 'package:docs_grid/features/documents/data/phone_trash_origin.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:docs_grid/features/tools/document_tools_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _pdf = '%PDF-1.7\\nDocsGrid restore integration fixture';
final _pdfBytes = Uint8List.fromList(utf8.encode(_pdf));
final _pdfHash = sha256.convert(_pdfBytes).toString();

Map<String, List<Map<String, Object?>>> _backupRows({
  bool withReminder = false,
  bool withFolder = false,
  bool withCollection = false,
}) => {
  'folders': withFolder ? [{
    'id': 'folder-1', 'name': 'Insurance', 'parent_id': null,
    'storage_uri_or_relative_path': null,
    'created_at': '2026-01-01T00:00:00Z',
    'updated_at': '2026-01-01T00:00:00Z', 'deleted_at': null,
  }] : <Map<String, Object?>>[],
  'documents': [{
    'id': 'document-1', 'name': 'Policy', 'original_name': 'Policy.pdf',
    'storage_uri': 'backup-pdf://document-1', 'relative_path': null,
    'mime_type': 'application/pdf', 'size_bytes': _pdfBytes.length,
    'sha256': _pdfHash, 'folder_id': withFolder ? 'folder-1' : null, 'category_id': null,
    'extracted_text_status': 'pending', 'expiry_date': null,
    'created_at': '2026-01-01T00:00:00Z', 'updated_at': '2026-01-01T00:00:00Z',
    'last_opened_at': null, 'deleted_at': null, 'source': null, 'metadata_json': null,
  }],
  'categories': <Map<String, Object?>>[],
  'tags': <Map<String, Object?>>[],
  'document_tags': <Map<String, Object?>>[],
  'reminders': withReminder ? [{
    'id': 'reminder-1', 'document_id': 'document-1', 'title': 'Renew policy',
    'note': null, 'remind_at_utc': '2035-01-01T09:00:00Z', 'timezone_id': 'UTC',
    'recurrence_rule': null, 'recurrence_end_at': null, 'lead_days': null,
    'enabled': 0, 'status': 'scheduled', 'snoozed_until': null,
    'next_fire_at_utc': '2035-01-01T09:00:00Z', 'notification_id': null,
    'created_at': '2026-01-01T00:00:00Z', 'updated_at': '2026-01-01T00:00:00Z',
    'completed_at': null,
  }] : <Map<String, Object?>>[],
  'history': <Map<String, Object?>>[],
  'settings': <Map<String, Object?>>[],
  'document_text_index': <Map<String, Object?>>[],
  'smart_collections': withCollection ? [{
    'id': 'collection-1', 'name': 'Recent policies', 'query_text': 'policy',
    'favorites_only': 0, 'recent_only': 1,
    'created_at': '2026-01-01T00:00:00Z',
    'updated_at': '2026-01-01T00:00:00Z',
  }] : <Map<String, Object?>>[],
};

Future<File> _makeBackup(Directory directory, {bool withReminder = false, bool withFolder = false, bool withCollection = false, bool deletedFolder = false, int documentCount = 1, bool identicalPayloads = false}) async {
  final archive = Archive();
  final rows = _backupRows(withReminder: withReminder, withFolder: withFolder, withCollection: withCollection);
  if (deletedFolder) {
    rows['folders']!.single['deleted_at'] = '2026-02-01T00:00:00Z';
    rows['documents']!.single['deleted_at'] = '2026-02-01T00:00:00Z';
  }
  final documentTemplate = Map<String, Object?>.from(rows['documents']!.single);
  final payloads = <String, Uint8List>{};
  rows['documents'] = List.generate(documentCount, (index) {
    final id = index == 0 ? 'document-1' : 'large-document-$index';
    final bytes = (index == 0 || identicalPayloads) ? _pdfBytes : Uint8List.fromList(utf8.encode('%PDF-1.7 document $index'));
    payloads[id] = bytes;
    return {...documentTemplate, 'id': id, 'sha256': sha256.convert(bytes).toString(),
      'size_bytes': bytes.length};
  });
  final metadataFiles = <Map<String, Object?>>[];
  for (final entry in rows.entries) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(entry.value)));
    final name = '${entry.key}.json';
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
    metadataFiles.add({
      'entry': name,
      'sizeBytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    });
  }
  for (final entry in payloads.entries) {
    archive.addFile(ArchiveFile('pdfs/${entry.key}.pdf', entry.value.length, entry.value));
  }
  final manifest = {
    'format': 'DocsGridBackup', 'version': 1, 'backupType': 'full',
    'backupId': 'restore-test', 'databaseSchemaVersion': 9,
    'createdAt': '2026-01-01T00:00:00Z',
    'tables': {for (final entry in rows.entries) entry.key: entry.value.length},
    'metadataFiles': metadataFiles,
    'files': [for (final entry in payloads.entries) {
      'documentId': entry.key, 'entry': 'pdfs/${entry.key}.pdf',
      'sha256': sha256.convert(entry.value).toString(), 'originalName': 'Policy.pdf',
    }],
  };
  final manifestBytes = Uint8List.fromList(utf8.encode(jsonEncode(manifest)));
  archive.addFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));
  final encoded = ZipEncoder().encode(archive);
  final file = File('${directory.path}/restore_fixture.zip');
  await file.writeAsBytes(encoded, flush: true);
  return file;
}

Future<Database> _openV7Database(Directory directory) async {
  final path = '${directory.path}/restore.db';
  final v1 = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 1,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, _) async {
        await db.execute('''CREATE TABLE folders (
          id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT,
          storage_uri_or_relative_path TEXT, created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL, deleted_at TEXT,
          FOREIGN KEY(parent_id) REFERENCES folders(id) ON DELETE RESTRICT)''');
        await db.execute('''CREATE TABLE documents (
          id TEXT PRIMARY KEY, name TEXT NOT NULL, original_name TEXT,
          storage_uri TEXT, relative_path TEXT,
          mime_type TEXT NOT NULL DEFAULT 'application/pdf',
          size_bytes INTEGER NOT NULL DEFAULT 0, sha256 TEXT, folder_id TEXT,
          category_id TEXT, extracted_text_status TEXT NOT NULL DEFAULT 'pending',
          expiry_date TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
          last_opened_at TEXT, deleted_at TEXT, source TEXT, metadata_json TEXT,
          FOREIGN KEY(folder_id) REFERENCES folders(id) ON DELETE RESTRICT)''');
        await db.execute('''CREATE TABLE reminders (
          id TEXT PRIMARY KEY, document_id TEXT, title TEXT NOT NULL, note TEXT,
          remind_at_utc TEXT NOT NULL, timezone_id TEXT NOT NULL,
          recurrence_rule TEXT, recurrence_end_at TEXT, lead_days INTEGER,
          enabled INTEGER NOT NULL DEFAULT 1, status TEXT NOT NULL DEFAULT 'scheduled',
          snoozed_until TEXT, next_fire_at_utc TEXT NOT NULL, notification_id INTEGER,
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL, completed_at TEXT,
          FOREIGN KEY(document_id) REFERENCES documents(id) ON DELETE SET NULL)''');
        await db.execute('CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)');
        await db.execute('CREATE INDEX idx_folders_parent ON folders(parent_id, deleted_at)');
        await db.execute('CREATE INDEX idx_documents_folder ON documents(folder_id, deleted_at)');
        await db.execute('CREATE INDEX idx_reminders_next_fire ON reminders(status, enabled, next_fire_at_utc)');
        await db.execute('CREATE INDEX idx_reminders_document ON reminders(document_id)');
      },
    ),
  );
  await v1.close();
  return databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: AppDatabase.schemaVersion,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onUpgrade: (db, oldVersion, newVersion) =>
          AppDatabase.forTesting(() async => db).upgradeForTesting(
            db, oldVersion, newVersion,
          ),
    ),
  );
}

Future<File> _makeExistingPdf(Directory directory) async {
  final file = File('${directory.path}/existing_policy.pdf');
  // Use different bytes from the archive fixture so this scenario tests an
  // ID collision, not the separate same-content deduplication path.
  final existingBytes = Uint8List.fromList(
    utf8.encode('%PDF-1.7\\nExisting local policy fixture'),
  );
  await file.writeAsBytes(existingBytes, flush: true);
  return file;
}

Future<void> _insertExistingDocument(
  Database db, {
  String id = 'document-1',
  required File pdfFile,
}) async {
  await db.insert('documents', {
    'id': id, 'name': 'Existing policy', 'mime_type': 'application/pdf',
    'storage_uri': pdfFile.path, 'relative_path': null,
    'size_bytes': await pdfFile.length(),
    'sha256': (await sha256.bind(pdfFile.openRead()).first).toString(),
    'created_at': '2025-01-01T00:00:00Z', 'updated_at': '2025-01-01T00:00:00Z',
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temp;
  late Directory appDocuments;
  late Directory appSupport;
  late Database db;
  late DocumentToolsService service;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('docsgrid_restore_integration_');
    appDocuments = Directory('${temp.path}/app_documents');
    appSupport = Directory('${temp.path}/app_support');
    await appDocuments.create(recursive: true);
    await appSupport.create(recursive: true);
    messenger.setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') return appDocuments.path;
      if (call.method == 'getApplicationSupportDirectory') return appSupport.path;
      if (call.method == 'getTemporaryDirectory') return temp.path;
      throw MissingPluginException('Unexpected path_provider method: ${call.method}');
    });
    db = await _openV7Database(temp);
    service = DocumentToolsService(database: AppDatabase.forTesting(() async => db));
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(const MethodChannel('docsgrid/storage'), null);
    await db.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });


  test('Phone PDF move deletes source; verified Grid copy appears in Grid Recent', () async {
    const sourceUri = 'content://media/external_primary/file/1000702003';
    final source = File('${temp.path}/10th result.pdf');
    final contents = utf8.encode('%PDF-1.7 phone-to-grid test PDF');
    await source.writeAsBytes(contents, flush: true);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(PhoneRecentHistory.storageKey, [
      jsonEncode({'uri': sourceUri, 'name': '10th result.pdf',
        'openedAt': '2026-11-17T11:12:00Z'}),
      jsonEncode({'uri': 'content://media/external_primary/file/5',
        'name': 'Other.pdf'}),
    ]);
    var deleted = false;
    messenger.setMockMethodCallHandler(const MethodChannel('docsgrid/storage'),
        (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      switch (call.method) {
        case 'copyPdfToPath':
          expect(args['sourceUri'], sourceUri);
          await source.copy(args['destinationPath'] as String);
          return true;
        case 'deletePdf':
          expect(args['uri'], sourceUri);
          deleted = true;
          await source.delete();
          return true;
        default:
          throw MissingPluginException('Unexpected storage call: ${call.method}');
      }
    });
    final repository = DocumentRepository(
        database: AppDatabase.forTesting(() async => db));
    final result = await repository.moveExternalPdfToGrid(
      sourceUri: sourceUri, displayName: '10th result.pdf',
    );
    expect(result.added, 1);
    expect(deleted, isTrue);
    expect(await source.exists(), isFalse);
    final recent = await repository.recentActivity();
    expect(recent, hasLength(1),
        reason: 'Newly added Grid PDFs are part of Grid Recent.');
    final gridFile = File(recent.single.storagePath);
    expect(await gridFile.exists(), isTrue);
    expect(await gridFile.readAsBytes(), orderedEquals(contents));
    expect(await PhoneRecentHistory.removeMovedSource(sourceUri), isTrue);
    final saved = prefs.getStringList(PhoneRecentHistory.storageKey)!;
    expect(saved, hasLength(1));
    expect(jsonDecode(saved.single)['uri'], 'content://media/external_primary/file/5');
  });

  test('Duplicate Phone move keeps Phone original and Phone Recent untouched', () async {
    const sourceUri = 'content://media/external_primary/file/120';
    final source = File('${temp.path}/duplicate_policy.pdf');
    await source.writeAsBytes(_pdfBytes);
    final originalGrid = File('${temp.path}/original_grid.pdf');
    await originalGrid.writeAsBytes(_pdfBytes);
    await _insertExistingDocument(db, id: 'already-in-grid', pdfFile: originalGrid);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final recentItem = jsonEncode({'uri': sourceUri, 'name': 'duplicate_policy.pdf'});
    await prefs.setStringList(PhoneRecentHistory.storageKey, [recentItem]);
    var deletes = 0;
    messenger.setMockMethodCallHandler(const MethodChannel('docsgrid/storage'),
        (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      switch (call.method) {
        case 'copyPdfToPath':
          await source.copy(args['destinationPath'] as String);
          return true;
        case 'deletePdf':
          deletes++;
          return true;
        default:
          throw MissingPluginException('Unexpected storage call: ${call.method}');
      }
    });
    final repository = DocumentRepository(
        database: AppDatabase.forTesting(() async => db));
    final result = await repository.moveExternalPdfToGrid(
      sourceUri: sourceUri, displayName: 'duplicate_policy.pdf');
    expect(result.added, 0);
    expect(result.duplicates, 1);
    expect(deletes, 0);
    expect(await source.exists(), isTrue);
    expect(prefs.getStringList(PhoneRecentHistory.storageKey), [recentItem]);
    expect(await repository.recentActivity(), hasLength(1));
  });

  test('Phone source delete denial preserves Phone Recent and verified Grid copy', () async {
    const sourceUri = 'content://media/external_primary/file/121';
    final source = File('${temp.path}/delete_denied.pdf');
    final contents = utf8.encode('%PDF-1.7 deletion denied');
    await source.writeAsBytes(contents);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final recentItem = jsonEncode({'uri': sourceUri, 'name': 'delete_denied.pdf'});
    await prefs.setStringList(PhoneRecentHistory.storageKey, [recentItem]);
    messenger.setMockMethodCallHandler(const MethodChannel('docsgrid/storage'),
        (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      switch (call.method) {
        case 'copyPdfToPath':
          await source.copy(args['destinationPath'] as String);
          return true;
        case 'deletePdf':
          return false; // Android did not authorize deletion of this provider.
        default:
          throw MissingPluginException('Unexpected storage call: ${call.method}');
      }
    });
    final repository = DocumentRepository(
        database: AppDatabase.forTesting(() async => db));
    await expectLater(
      repository.moveExternalPdfToGrid(
          sourceUri: sourceUri, displayName: 'delete_denied.pdf'),
      throwsStateError,
    );
    expect(await source.readAsBytes(), orderedEquals(contents));
    expect(prefs.getStringList(PhoneRecentHistory.storageKey), [recentItem]);
    final grid = await repository.recentActivity();
    expect(grid, hasLength(1));
    expect(await File(grid.single.storagePath).readAsBytes(),
        orderedEquals(contents));
  });

  test('verified Insurance mapping survives five restores without extra PDF copies', () async {
    final original = Directory('${appDocuments.path}/Folders/Insurance');
    await original.create(recursive: true);
    final row = Map<String, Object?>.from(_backupRows(withFolder: true)['folders']!.single);
    row['storage_uri_or_relative_path'] = original.path;
    await db.insert('folders', row);
    final backup = await _makeBackup(temp, withFolder: true, withReminder: true);
    for (var i = 0; i < 5; i++) {
      expect(await service.restoreBackup(backup, confirm: (_) async => true), i == 0 ? 1 : 0);
    }
    final folders = await db.query('folders');
    expect(folders, hasLength(1));
    expect(folders.single['storage_uri_or_relative_path'], original.path);
    expect(await db.query('documents'), hasLength(1));
    expect(await db.query('reminders'), hasLength(1));
    final documents = await db.query('documents');
    expect(File(documents.single['storage_uri'] as String).parent.path, original.path);
    expect(await original.list().length, 1);
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });


  test('old Restored Insurance is repaired; next PDF uses original folder', () async {
    final base = Directory('${appDocuments.path}/DocsGrid/Library/Folders');
    final original = Directory('${base.path}/Insurance');
    final legacy = Directory('${base.path}/Restored_1794904040961709/Insurance_360d1ef9');
    await original.create(recursive: true);
    await legacy.create(recursive: true);
    final oldBytes = utf8.encode('%PDF-1.7 independent legacy policy');
    final oldPdf = File('${legacy.path}/old.pdf');
    await oldPdf.writeAsBytes(oldBytes);
    await db.insert('folders', {
      ..._backupRows(withFolder: true)['folders']!.single,
      'storage_uri_or_relative_path': Uri.file(legacy.path).toString(),
    });
    await db.insert('documents', {
      'id': 'legacy-doc', 'name': 'Old policy', 'mime_type': 'application/pdf',
      'folder_id': 'folder-1', 'storage_uri': Uri.file(oldPdf.path).toString(),
      'sha256': sha256.convert(oldBytes).toString(), 'size_bytes': oldBytes.length,
      'created_at': '2025-01-01T00:00:00Z',
      'updated_at': '2025-01-01T00:00:00Z',
    });
    final zip = await _makeBackup(temp, withFolder: true);
    Map<String, int>? preview;
    expect(await service.restoreBackup(zip, confirm: (_) async => true,
        confirmPlan: (value) async {preview = value; return true;}), 1);
    expect(preview!['legacyFolderRepairs'], 1);
    expect(preview!['legacyPdfsToCopy'], 1);
    expect((await db.query('folders')).single['storage_uri_or_relative_path'],
        original.path);
    expect((await db.query('documents')).length, 2);
    for (final row in await db.query('documents')) {
      final uri = row['storage_uri'] as String;
      final path = uri.startsWith('file://') ? Uri.parse(uri).toFilePath() : uri;
      expect(File(path).parent.path, original.path);
      expect(await File(path).exists(), isTrue);
    }
    expect(await oldPdf.readAsBytes(), orderedEquals(oldBytes));
    expect(await service.restoreBackup(zip, confirm: (_) async => true,
        confirmPlan: (_) async => true), 0);
    expect(await original.list().length, 2);
    messenger.setMockMethodCallHandler(const MethodChannel('docsgrid/storage'), (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      if (call.method == 'copyPdf') {
        expect(args['parentUri'], original.path);
        final input = File.fromUri(Uri.parse(args['sourceUri'] as String));
        return (await input.copy('${original.path}/${args['name']}')).uri.toString();
      }
      if (call.method == 'sha256Pdf') {
        final input = File.fromUri(Uri.parse(args['uri'] as String));
        return (await sha256.bind(input.openRead()).first).toString();
      }
      throw MissingPluginException('Unexpected import channel operation');
    });
    final incoming = File('${temp.path}/new.pdf');
    await incoming.writeAsString('%PDF-1.7 brand new document');
    final summary = await DocumentRepository(
        database: AppDatabase.forTesting(() async => db))
        .importScannedPdf(incoming, targetFolderId: 'folder-1');
    expect(summary.added, 1);
    expect(await original.list().length, 3);
    expect(await oldPdf.exists(), isTrue);
  });

  test('declined legacy folder repair leaves original and old storage untouched', () async {
    final base = Directory('${appDocuments.path}/DocsGrid/Library/Folders');
    final original = Directory('${base.path}/Insurance');
    final legacy = Directory('${base.path}/Restored_1794904040961709/Insurance_360d1ef9');
    await original.create(recursive: true);
    await legacy.create(recursive: true);
    await db.insert('folders', {
      ..._backupRows(withFolder: true)['folders']!.single,
      'storage_uri_or_relative_path': legacy.path,
    });
    final old = File('${legacy.path}/old.pdf');
    await old.writeAsBytes(_pdfBytes);
    await db.insert('documents', {
      'id': 'old-doc', 'name': 'Old', 'mime_type': 'application/pdf',
      'folder_id': 'folder-1', 'storage_uri': old.path,
      'sha256': _pdfHash, 'size_bytes': _pdfBytes.length,
      'created_at': '2025-01-01T00:00:00Z',
      'updated_at': '2025-01-01T00:00:00Z',
    });
    final zip = await _makeBackup(temp, withFolder: true);
    Map<String, int>? preview;
    expect(await service.restoreBackup(zip, confirm: (_) async => true,
        confirmPlan: (value) async {preview = value; return false;}), isNull);
    expect(preview!['legacyFolderRepairs'], 1);
    expect((await db.query('folders')).single['storage_uri_or_relative_path'], legacy.path);
    expect(await old.readAsBytes(), orderedEquals(_pdfBytes));
    expect(await original.list().length, 0);
  });

  test('legacy SHA mismatch fails before changing any mapping', () async {
    final base = Directory('${appDocuments.path}/DocsGrid/Library/Folders');
    final original = Directory('${base.path}/Insurance');
    final legacy = Directory('${base.path}/Restored_1794904040961709/Insurance_360d1ef9');
    await original.create(recursive: true);
    await legacy.create(recursive: true);
    await db.insert('folders', {
      ..._backupRows(withFolder: true)['folders']!.single,
      'storage_uri_or_relative_path': legacy.path,
    });
    final old = File('${legacy.path}/old.pdf');
    await old.writeAsString('%PDF-1.7 wrong original contents');
    await db.insert('documents', {
      'id': 'old-doc', 'name': 'Old', 'mime_type': 'application/pdf',
      'folder_id': 'folder-1', 'storage_uri': old.path,
      'sha256': _pdfHash, 'size_bytes': _pdfBytes.length,
      'created_at': '2025-01-01T00:00:00Z',
      'updated_at': '2025-01-01T00:00:00Z',
    });
    final zip = await _makeBackup(temp, withFolder: true);
    await expectLater(service.restoreBackup(zip, confirm: (_) async => true,
        confirmPlan: (_) async => true), throwsA(isA<StateError>()));
    expect((await db.query('folders')).single['storage_uri_or_relative_path'], legacy.path);
    expect(await original.list().length, 0);
    expect(await old.readAsString(), '%PDF-1.7 wrong original contents');
  });

  test('physical Insurance without a database row is reused after hash verification', () async {
    final original = Directory('${appDocuments.path}/DocsGrid/Library/Folders/Insurance');
    await original.create(recursive: true);
    final pdf = File('${original.path}/original.pdf');
    await pdf.writeAsBytes(_pdfBytes);
    final backup = await _makeBackup(temp, withFolder: true);
    expect(await service.restoreBackup(backup, confirm: (_) async => true), 0);
    final folders = await db.query('folders');
    expect(folders.single['storage_uri_or_relative_path'], original.path);
    expect((await db.query('documents')).single['storage_uri'], pdf.path);
    expect(await original.list().length, 1);
  });

  test('independent records with identical PDF bytes keep distinct physical files', () async {
    final backup = await _makeBackup(temp, withFolder: true,
        documentCount: 2, identicalPayloads: true);
    expect(await service.restoreBackup(backup, confirm: (_) async => true), 2);
    final documents = await db.query('documents');
    expect(documents, hasLength(2));
    final physicalPaths = documents.map((row) => row['storage_uri'] as String).toSet();
    expect(physicalPaths, hasLength(2),
        reason: 'Move or delete of one document must never invalidate another.');
    for (final path in physicalPaths) {
      expect(await File(path).exists(), isTrue);
      expect((await sha256.bind(File(path).openRead()).first).toString(), _pdfHash);
    }
    expect(await service.restoreBackup(backup, confirm: (_) async => true), 0);
    expect(await db.query('documents'), hasLength(2));
  });

  test('existing same-hash document never shares its physical file with another record', () async {
    final existing = File('${temp.path}/existing_same_content.pdf');
    await existing.writeAsBytes(_pdfBytes);
    await _insertExistingDocument(db, id: 'other-document', pdfFile: existing);
    final backup = await _makeBackup(temp, withFolder: true);
    expect(await service.restoreBackup(backup, confirm: (_) async => true), 1);
    final all = await db.query('documents');
    expect(all, hasLength(2));
    final restored = all.singleWhere((row) => row['id'] == 'document-1');
    expect(restored['storage_uri'], isNot(existing.path));
    expect(await existing.readAsBytes(), orderedEquals(_pdfBytes));
  });

  test('same path with different identity fails without touching original', () async {
    await db.insert('folders', {
      ..._backupRows(withFolder: true)['folders']!.single,
      'id': 'unrelated', 'created_at': '2020-01-01T00:00:00Z',
    });
    final backup = await _makeBackup(temp, withFolder: true);
    await expectLater(service.restoreBackup(backup, confirm: (_) async => true),
        throwsA(isA<StateError>()));
    expect(await db.query('folders'), hasLength(1));
    expect(await db.query('documents'), isEmpty);
  });

  test('preview cancellation performs no library mutation', () async {
    final backup = await _makeBackup(temp, withFolder: true);
    Map<String, int>? preview;
    expect(await service.restoreBackup(backup, confirm: (_) async => true,
      confirmPlan: (plan) async { preview = plan; return false; }), isNull);
    expect(preview!['newPdfs'], 1);
    expect(preview!['newFolders'], 1);
    expect(await db.query('folders'), isEmpty);
    expect(await db.query('documents'), isEmpty);
    // No restore checkpoint or full ZIP backup is allowed before a plan is
    // accepted. A cancelled preview must not consume backup retention slots.
    final fullBackups = Directory('${appDocuments.path}/DocsGrid/Backups/Full');
    if (await fullBackups.exists()) {
      expect(await fullBackups.list().toList(), isEmpty);
    }
  });

  test('library write during preview invalidates plan', () async {
    final backup = await _makeBackup(temp, withFolder: true);
    await expectLater(service.restoreBackup(backup, confirm: (_) async => true,
      confirmPlan: (_) async {
        await db.insert('folders', {'id': 'concurrent', 'name': 'Other',
          'created_at': '2026-01-01', 'updated_at': '2026-01-01'});
        return true;
      }), throwsA(isA<StateError>()));
    expect((await db.query('folders')).single['id'], 'concurrent');
    expect(await db.query('documents'), isEmpty);
  });

  test('same filename different contents never overwrites original bytes', () async {
    final original = Directory('${appDocuments.path}/DocsGrid/Library/Folders/Insurance');
    await original.create(recursive: true);
    final pdf = File('${original.path}/Policy.pdf');
    await pdf.writeAsString('%PDF-1.7 original protected');
    final backup = await _makeBackup(temp, withFolder: true);
    expect(await service.restoreBackup(backup, confirm: (_) async => true), 1);
    expect(await pdf.readAsString(), '%PDF-1.7 original protected');
    expect(await original.list().length, 2);
  });

  Future<Directory> mockSnapshotStorage({bool corruptRead = false,
      Future<void> Function()? duringWrite}) async {
    final root = Directory('${temp.path}/snapshots');
    await root.create();
    var changed = false;
    messenger.setMockMethodCallHandler(const MethodChannel('docsgrid/storage'), (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      switch (call.method) {
        case 'createDirectory':
          final directory = Directory('${Uri.parse(args['parentUri'] as String).toFilePath()}/${args['name']}');
          await directory.create();
          return directory.uri.toString();
        case 'writeTextFile':
          final file = File('${Uri.parse(args['parentUri'] as String).toFilePath()}/${args['name']}');
          await file.writeAsString(args['contents'] as String);
          if (!changed && duringWrite != null) { changed = true; await duringWrite(); }
          return file.uri.toString();
        case 'readTextFile':
          final file = File.fromUri(Uri.parse(args['uri'] as String));
          if (corruptRead && file.path.endsWith('folders.json')) return 'corrupt';
          return file.readAsString();
        case 'listDirectory':
          final directory = Directory.fromUri(Uri.parse(args['uri'] as String));
          return [for (final file in await directory.list().toList()) {
            'uri': file.uri.toString(), 'name': file.uri.pathSegments.where((s) => s.isNotEmpty).last,
            'isDirectory': file is Directory,
          }];
      }
      throw MissingPluginException('Unexpected snapshot method: ${call.method}');
    });
    service = DocumentToolsService(database: AppDatabase.forTesting(() async => db),
      snapshotLocations: () async => {'databaseUri': root.uri.toString()});
    return root;
  }

  test('snapshot readback verified and unchanged revision creates no second directory', () async {
    final root = await mockSnapshotStorage();
    final first = await service.createPortableMetadataSnapshot();
    expect(await service.createPortableMetadataSnapshot(), first);
    expect(await root.list().length, 1);
    expect(await AppDatabase.forTesting(() async => db).isPortableSnapshotDirty(), isFalse);
  });

  test('missing published snapshot forces a fresh verified recovery point', () async {
    final root = await mockSnapshotStorage();
    final previous = await service.createPortableMetadataSnapshot();
    await Directory('${root.path}/$previous').delete(recursive: true);
    final replacement = await service.createPortableMetadataSnapshot();
    expect(replacement, isNot(previous));
    expect(await Directory('${root.path}/$replacement').exists(), isTrue);
    expect(await service.createPortableMetadataSnapshot(), replacement);
  });

  test('snapshot verification failure preserves dirty revision and older content', () async {
    final root = await mockSnapshotStorage(corruptRead: true);
    final unknown = File('${root.path}/user-notes.txt');
    await unknown.writeAsString('keep');
    await expectLater(service.createPortableMetadataSnapshot(), throwsA(isA<StateError>()));
    expect(await AppDatabase.forTesting(() async => db).isPortableSnapshotDirty(), isTrue);
    expect(await unknown.readAsString(), 'keep');
  });

  test('database write during snapshot stays dirty for subsequent capture', () async {
    await mockSnapshotStorage(duringWrite: () async {
      await db.insert('folders', {'id': 'concurrent', 'name': 'Later',
        'created_at': '2026-01-01', 'updated_at': '2026-01-01'});
    });
    await service.createPortableMetadataSnapshot();
    expect(await AppDatabase.forTesting(() async => db).isPortableSnapshotDirty(), isTrue);
    await service.createPortableMetadataSnapshot();
    expect(await AppDatabase.forTesting(() async => db).isPortableSnapshotDirty(), isFalse);
  });

  test('verified retention prunes only owned complete snapshots', () async {
    final root = await mockSnapshotStorage();
    final unknown = Directory('${root.path}/snapshot_unknown');
    await unknown.create();
    await File('${unknown.path}/keep.pdf').writeAsString('user content');
    for (var i = 0; i < 10; i++) {
      await db.insert('folders', {'id': 'folder-$i', 'name': 'Folder $i',
        'created_at': '2026-01-01', 'updated_at': '2026-01-01'});
      await service.createPortableMetadataSnapshot();
    }
    expect(await root.list().length, lessThanOrEqualTo(9));
    expect(await File('${unknown.path}/keep.pdf').readAsString(), 'user content');
    expect(DocumentToolsService.snapshotDiagnostics['removedSnapshots'], greaterThan(0));
  });

  test('deleted source folder retains deleted state without revival', () async {
    final backup = await _makeBackup(temp, withFolder: true, deletedFolder: true);
    expect(await service.restoreBackup(backup, confirm: (_) async => true), 1);
    expect((await db.query('folders')).single['deleted_at'], isNotNull);
    expect((await db.query('documents')).single['deleted_at'], isNotNull);
    expect(await service.restoreBackup(backup, confirm: (_) async => true), 0);
    expect(await db.query('folders'), hasLength(1));
    expect(await db.query('documents'), hasLength(1));
  });

  test('deleted backup folder never merges into same-name active folder', () async {
    await db.insert('folders', _backupRows(withFolder: true)['folders']!.single);
    final backup = await _makeBackup(temp, withFolder: true, deletedFolder: true);
    await expectLater(service.restoreBackup(backup, confirm: (_) async => true), throwsA(isA<StateError>()));
    expect((await db.query('folders')).single['deleted_at'], isNull);
    expect(await db.query('documents'), isEmpty);
  });

  test('new PDF import after restore uses the verified original Insurance folder', () async {
    final original = Directory('${appDocuments.path}/Folders/Insurance');
    await original.create(recursive: true);
    await db.insert('folders', {..._backupRows(withFolder: true)['folders']!.single,
      'storage_uri_or_relative_path': original.path});
    final backup = await _makeBackup(temp, withFolder: true);
    await service.restoreBackup(backup, confirm: (_) async => true);
    messenger.setMockMethodCallHandler(const MethodChannel('docsgrid/storage'), (call) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      if (call.method == 'copyPdf') {
        expect(args['parentUri'], original.path);
        final source = File.fromUri(Uri.parse(args['sourceUri'] as String));
        return (await source.copy('${original.path}/${args['name']}')).uri.toString();
      }
      if (call.method == 'sha256Pdf') {
        final file = File.fromUri(Uri.parse(args['uri'] as String));
        return (await sha256.bind(file.openRead()).first).toString();
      }
      throw MissingPluginException('Unexpected import call: ${call.method}');
    });
    final incoming = File('${temp.path}/new.pdf');
    await incoming.writeAsString('%PDF-1.7 new imported policy');
    final repository = DocumentRepository(database: AppDatabase.forTesting(() async => db));
    expect((await repository.importScannedPdf(incoming, targetFolderId: 'folder-1')).added, 1);
    final rows = await db.query('documents', where: 'id != ?', whereArgs: ['document-1']);
    final imported = File.fromUri(Uri.parse(rows.single['storage_uri'] as String));
    expect(imported.parent.path, original.path);
    expect(await imported.readAsBytes(), await incoming.readAsBytes());
    expect(await original.list().length, 2);
  });

  test('incomplete snapshot cleanup requires ownership, grace and two valid points', () async {
    final root = await mockSnapshotStorage();
    Future<Directory> incomplete(String name, int hours, {bool owned = true}) async {
      final directory = Directory('${root.path}/$name');
      await directory.create();
      await File('${directory.path}/folders.json').writeAsString('[]');
      if (owned) await File('${directory.path}/operation.json').writeAsString(jsonEncode({
        'format': 'DocsGridSnapshotOperation', 'version': 1, 'directoryName': name,
        'createdAtUtc': DateTime.now().toUtc().subtract(Duration(hours: hours)).toIso8601String(),
      }));
      return directory;
    }
    final old = await incomplete('snapshot_interrupted_old', 72);
    final recent = await incomplete('snapshot_interrupted_recent', 1);
    final unknown = await incomplete('snapshot_legacy_unknown', 720, owned: false);
    await service.createPortableMetadataSnapshot();
    expect(await old.exists(), isTrue);
    await db.insert('folders', {'id': 'later', 'name': 'Later',
      'created_at': '2026-01-01', 'updated_at': '2026-01-01'});
    await service.createPortableMetadataSnapshot();
    expect(await old.exists(), isFalse);
    expect(await recent.exists(), isTrue);
    expect(await unknown.exists(), isTrue);
  });

  for (final count in [1000, 10000]) {
    test('streamed ZIP restore with $count small PDF payloads', () async {
      final backup = await _makeBackup(temp, withFolder: true, documentCount: count);
      final timer = Stopwatch()..start();
      expect(await service.restoreBackup(backup, confirm: (_) async => true), count);
      expect((await db.rawQuery('SELECT COUNT(*) AS count FROM documents')).single['count'], count);
      expect(await db.query('folders'), hasLength(1));
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      // Fixture throughput only, not a real-device/large-PDF certification.
      // ignore: avoid_print
      print('Restore fixture: $count PDFs in ${timer.elapsedMilliseconds} ms');
    }, timeout: const Timeout(Duration(minutes: 5)));
  }

  test('schema upgrade creates the Smart Collections table and index', () async {
    final tables = await db.query(
      'sqlite_master',
      columns: ['name'],
      where: "type = 'table' AND name = ?",
      whereArgs: ['smart_collections'],
    );
    expect(tables, hasLength(1));
    final indexes = await db.query(
      'sqlite_master',
      columns: ['name'],
      where: "type = 'index' AND name = ?",
      whereArgs: ['idx_smart_collections_name'],
    );
    expect(indexes, hasLength(1));
  });

  test('Merge restores PDFs and remaps an existing document ID collision', () async {
    await _insertExistingDocument(
      db,
      pdfFile: await _makeExistingPdf(temp),
    );
    final backup = await _makeBackup(temp);
    final restored = await service.restoreBackup(
      backup, confirm: (_) async => true, mode: BackupRestoreMode.merge,
    );
    expect(restored, 1);
    final documents = await db.query('documents', orderBy: 'id');
    expect(documents, hasLength(2));
    final imported = documents.singleWhere((row) => row['id'] != 'document-1');
    final restoredFile = File(imported['storage_uri'] as String);
    expect(await restoredFile.exists(), isTrue);
    expect(
      await sha256.bind(restoredFile.openRead()).first.then((digest) => digest.toString()),
      _pdfHash,
    );
  });

  test('Merge remaps a folder ID already owned by a soft-deleted folder', () async {
    await db.insert('folders', {
      'id': 'folder-1', 'name': 'Old folder',
      'created_at': '2025-01-01T00:00:00Z',
      'updated_at': '2025-01-01T00:00:00Z',
      'deleted_at': '2025-02-01T00:00:00Z',
    });
    final backup = await _makeBackup(temp, withFolder: true);
    final restored = await service.restoreBackup(
      backup, confirm: (_) async => true, mode: BackupRestoreMode.merge,
    );
    expect(restored, 1);
    final folders = await db.query('folders', orderBy: 'id');
    expect(folders, hasLength(2));
    expect(
      folders.where((row) => row['id'] == 'folder-1' && row['deleted_at'] != null),
      hasLength(1),
    );
    final activeFolders = folders.where((row) => row['deleted_at'] == null).toList();
    expect(activeFolders, hasLength(1));
    expect(activeFolders.single['id'], isNot('folder-1'));
    final documents = await db.query('documents');
    expect(documents.single['folder_id'], activeFolders.single['id']);
  });

  test('Full Replacement removes nested old folders child-first and restores backup', () async {
    await db.insert('folders', {
      'id': 'old-root', 'name': 'Old', 'created_at': '2025-01-01',
      'updated_at': '2025-01-01',
    });
    await db.insert('folders', {
      'id': 'old-child', 'name': 'Child', 'parent_id': 'old-root',
      'created_at': '2025-01-01', 'updated_at': '2025-01-01',
    });
    final backup = await _makeBackup(temp);
    final restored = await service.restoreBackup(
      backup, confirm: (_) async => true, mode: BackupRestoreMode.fullReplacement,
    );
    expect(restored, 1);
    expect(await db.query('folders'), isEmpty);
    expect(await db.query('documents'), hasLength(1));
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });


  test('real full Backup Restore updates Home cache on relaunch and later changes', () async {
    SharedPreferences.setMockInitialValues({});
    final cache = HomeDashboardCache();
    final repo = DocumentRepository(database: AppDatabase.forTesting(() async => db));
    final emptySummary = await repo.dashboardSummary();
    expect(emptySummary.documentCount, 0);
    await cache.saveSummary(
      documentCount: emptySummary.documentCount,
      favoriteCount: emptySummary.favoriteCount,
      totalBytes: emptySummary.totalBytes,
    );
    await cache.saveRecentNames([]);
    expect((await HomeDashboardCache().readSummary())?.documentCount, 0);

    // Use the same production restore service and migrated SQLite schema as
    // the existing backup/restore integration suite (not a mocked restore).
    final backup = await _makeBackup(temp);
    expect(await service.restoreBackup(
      backup, confirm: (_) async => true, mode: BackupRestoreMode.fullReplacement,
    ), 1);
    // Old presentation snapshot is still marked provisional; no cached
    // document IDs/paths/actions can be executed.
    expect((await HomeDashboardCache().readSummary())?.documentCount, 0);
    final restored = await repo.dashboardSummary();
    expect(restored.documentCount, 1);
    expect(restored.favoriteCount, 0);
    expect(restored.totalBytes, _pdfBytes.length);
    await cache.saveSummary(
      documentCount: restored.documentCount,
      favoriteCount: restored.favoriteCount,
      totalBytes: restored.totalBytes,
    );
    await cache.saveRecentNames(['Policy']);
    final afterRelaunch = HomeDashboardCache();
    expect((await afterRelaunch.readSummary())?.documentCount, 1);
    expect(await afterRelaunch.readRecentNames(), ['Policy']);

    // A real SQLite UPDATE increments the summary revision via the actual
    // trigger; the repository may not reuse its previous cached aggregate.
    await db.update('documents', {'is_favorite': 1},
        where: 'id = ?', whereArgs: ['document-1']);
    final starred = await repo.dashboardSummary();
    expect(starred.documentCount, 1);
    expect(starred.favoriteCount, 1);
    await cache.saveSummary(
      documentCount: starred.documentCount,
      favoriteCount: starred.favoriteCount,
      totalBytes: starred.totalBytes,
    );
    expect((await HomeDashboardCache().readSummary())?.favoriteCount, 1);

    // A soft deletion must not leave phantom PDF counts in the next snapshot.
    await db.update('documents', {'deleted_at': '2026-11-21T00:00:00Z'},
        where: 'id = ?', whereArgs: ['document-1']);
    final deleted = await repo.dashboardSummary();
    expect(deleted.documentCount, 0);
    expect(deleted.favoriteCount, 0);
    expect(deleted.totalBytes, 0);
    await cache.saveSummary(
      documentCount: deleted.documentCount,
      favoriteCount: deleted.favoriteCount,
      totalBytes: deleted.totalBytes,
    );
    await cache.saveRecentNames([]);
    final afterDeletionRelaunch = HomeDashboardCache();
    expect((await afterDeletionRelaunch.readSummary())?.documentCount, 0);
    expect((await afterDeletionRelaunch.readSummary())?.totalBytes, 0);
    expect(await afterDeletionRelaunch.readRecentNames(), isEmpty);
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });

  test('Selective Smart Collections restore saved filters without touching documents', () async {
    final backup = await _makeBackup(temp, withCollection: true);
    await service.restoreBackup(
      backup,
      confirm: (_) async => true,
      mode: BackupRestoreMode.selective,
      selection: {BackupRestoreSection.smartCollections},
    );
    final collections = await db.query('smart_collections');
    expect(collections, hasLength(1));
    expect(collections.single['name'], 'Recent policies');
    expect(collections.single['query_text'], 'policy');
    expect(collections.single['recent_only'], 1);
    expect(await db.query('documents'), isEmpty);
  });

  test('Selective reminders retain links to documents already on this device', () async {
    await _insertExistingDocument(
      db,
      pdfFile: await _makeExistingPdf(temp),
    );
    final backup = await _makeBackup(temp, withReminder: true);
    await service.restoreBackup(
      backup,
      confirm: (_) async => true,
      mode: BackupRestoreMode.selective,
      selection: {BackupRestoreSection.reminders},
    );
    final reminders = await db.query('reminders');
    expect(reminders, hasLength(1));
    expect(reminders.single['document_id'], 'document-1');
    expect(await db.query('documents'), hasLength(1));
  });

  test('failed database insert rolls back rows and cleans staged restore files', () async {
    await db.execute('''CREATE TRIGGER fail_restore_document
      BEFORE INSERT ON documents BEGIN SELECT RAISE(ABORT, 'forced restore failure'); END''');
    final backup = await _makeBackup(temp);
    await expectLater(
      service.restoreBackup(backup, confirm: (_) async => true),
      throwsA(anything),
    );
    expect(await db.query('documents'), isEmpty);
    final restoreRoot = Directory('${appDocuments.path}/DocsGrid/Library');
    if (await restoreRoot.exists()) {
      final remaining = await restoreRoot.list(recursive: true).where((entry) => entry is File).toList();
      expect(
        remaining,
        isEmpty,
        reason: 'Failed restores must remove only their newly staged PDFs; original directories survive.',
      );
    }
  });

  test('two Phone PDFs archived: empty folder stays shown until final Restore',
      () async {
    final phoneRoot = Directory('${temp.path}/phone-root');
    final originalFolder = Directory('${phoneRoot.path}/Work');
    await originalFolder.create(recursive: true);
    final rootUri = Uri.file(phoneRoot.path).toString();
    final roots = [
      {'uri': rootUri, 'name': 'Internal storage'},
    ];
    final a = File('${originalFolder.path}/January.pdf');
    final b = File('${originalFolder.path}/February.pdf');
    await a.writeAsString('%PDF-1.7 January original');
    await b.writeAsString('%PDF-1.7 February original');
    final aUri = Uri.file(a.path).toString();
    final bUri = Uri.file(b.path).toString();
    var storageAuthorized = true;

    String filePathFor(String uri) {
      final parsed = Uri.tryParse(uri);
      return parsed?.scheme == 'file' ? parsed!.toFilePath() : uri;
    }

    messenger.setMockMethodCallHandler(const MethodChannel('docsgrid/storage'),
        (call) async {
      final args = call.arguments is Map
          ? Map<String, dynamic>.from(call.arguments as Map)
          : <String, dynamic>{};
      switch (call.method) {
        case 'getSelectedFolder':
          return null;
        case 'getAccessibleScanRoots':
          return storageAuthorized ? roots : <Map<String, String>>[];
        case 'copyPdfToPath':
          final source = File(filePathFor(args['sourceUri'] as String));
          await source.copy(args['destinationPath'] as String);
          return true;
        case 'sha256Pdf':
          return (await sha256.bind(File(
            filePathFor(args['uri'] as String)).openRead()).first).toString();
        case 'findChildUri':
          final target = File('${filePathFor(args['parentUri'] as String)}/${args['name']}');
          if (!await target.exists() && !await Directory(target.path).exists()) {
            throw PlatformException(code: 'NOT_FOUND', message: 'Not present');
          }
          return Uri.file(target.path).toString();
        case 'createDirectory':
          final target = Directory('${filePathFor(args['parentUri'] as String)}/${args['name']}');
          await target.create(recursive: false);
          return Uri.file(target.path).toString();
        case 'copyFileToStorage':
          final destination = File('${filePathFor(args['parentUri'] as String)}/${args['name']}');
          if (await destination.exists()) {
            throw StateError('Restore tried to overwrite a Phone PDF.');
          }
          await File(args['sourcePath'] as String).copy(destination.path);
          return Uri.file(destination.path).toString();
        case 'deletePdf':
          final file = File(filePathFor(args['uri'] as String));
          if (await file.exists()) await file.delete();
          return true;
        default:
          throw MissingPluginException('Unknown test storage call: ${call.method}');
      }
    });

    final repository = DocumentRepository(
      database: AppDatabase.forTesting(() async => db),
      phoneRootsForTesting: () async =>
          storageAuthorized ? roots : <Map<String, String>>[],
    );
    PhoneTrashOrigin origin(String sourceUri, String name) =>
        PhoneTrashOrigin(
          sourceUri: sourceUri,
          rootUri: rootUri,
          folderPath: 'Internal/Work',
          displayName: name,
        );

    expect(await repository.moveExternalPdfToTrash(
      sourceUri: aUri,
      displayName: 'January.pdf',
      origin: origin(aUri, 'January.pdf'),
    ), isTrue);
    expect(await repository.moveExternalPdfToTrash(
      sourceUri: bUri,
      displayName: 'February.pdf',
      origin: origin(bUri, 'February.pdf'),
    ), isTrue);
    expect(await a.exists(), isFalse);
    expect(await b.exists(), isFalse);
    expect(await originalFolder.exists(), isTrue,
        reason: 'Deleting the last PDF must not delete its Phone folder.');
    var trash = await repository.listTrash();
    expect(trash, hasLength(2));
    var placeholders = await repository.phoneTrashFolderEntries();
    expect(placeholders, hasLength(1));
    expect(placeholders.single['path'], 'Internal/Work');
    expect(placeholders.single['trashPdfCount'], 2);
    expect(placeholders.single['isPending'], isTrue);
    expect(await repository.list(), isEmpty,
        reason: 'Archived Phone copies must not leak into active Grid.');

    // Even if a file manager physically removes the empty folder, its
    // Recycle Bin-backed location survives and Restore recreates it under
    // the original approved Phone storage root.
    await originalFolder.delete();
    expect(await originalFolder.exists(), isFalse);

    // If the original SD/Phone access is temporarily unavailable, Restore
    // must be refused without removing the PDF from Recycle Bin.
    storageAuthorized = false;
    await expectLater(
      repository.restoreFromTrash(trash.first), throwsStateError,
    );
    expect(await repository.listTrash(), hasLength(2));
    expect(await a.exists(), isFalse);
    storageAuthorized = true;

    await repository.restoreFromTrash(
      trash.firstWhere((d) => d.name == 'January'),
    );
    expect(await a.readAsString(), '%PDF-1.7 January original');
    expect(await b.exists(), isFalse);
    trash = await repository.listTrash();
    expect(trash, hasLength(1));
    placeholders = await repository.phoneTrashFolderEntries();
    expect(placeholders.single['trashPdfCount'], 1);
    expect(await repository.list(), isEmpty,
        reason: 'Restored Phone PDF must not appear in Grid Storage.');

    await repository.restoreFromTrash(trash.single);
    expect(await b.readAsString(), '%PDF-1.7 February original');
    expect(await repository.listTrash(), isEmpty);
    expect(await repository.phoneTrashFolderEntries(), isEmpty,
        reason: 'The virtual folder hold ends when no archived PDFs remain.');
    expect(await repository.list(), isEmpty);
  });

  test('legacy Phone archive without origin is held in Trash, not sent to Grid',
      () async {
    final archive = File('${temp.path}/archive.pdf');
    await archive.writeAsString('%PDF-1.7 old archive');
    await db.insert('documents', {
      'id': 'old-phone-trash',
      'name': 'Legacy',
      'storage_uri': archive.path,
      'sha256': (await sha256.bind(archive.openRead()).first).toString(),
      'mime_type': 'application/pdf',
      'size_bytes': await archive.length(),
      'created_at': '2026-11-17T00:00:00Z',
      'updated_at': '2026-11-17T00:00:00Z',
      'deleted_at': '2026-11-17T01:00:00Z',
      'metadata_json': '{}',
      'source': 'phone_storage_recycle_bin',
    });
    final repository = DocumentRepository(
        database: AppDatabase.forTesting(() async => db));
    final old = (await repository.listTrash()).single;
    await expectLater(repository.restoreFromTrash(old), throwsStateError);
    expect(await repository.listTrash(), hasLength(1));
    expect(await archive.exists(), isTrue);
    expect(await repository.list(), isEmpty);
  });

}
