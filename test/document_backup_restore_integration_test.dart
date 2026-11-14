import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:docs_grid/core/database/app_database.dart';
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

Future<File> _makeBackup(Directory directory, {bool withReminder = false, bool withFolder = false, bool withCollection = false, bool databaseOnly = false, String fileName = 'restore_fixture.zip'}) async {
  final archive = Archive();
  final rows = _backupRows(withReminder: withReminder, withFolder: withFolder, withCollection: withCollection);
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
  if (!databaseOnly) archive.addFile(ArchiveFile('pdfs/policy.pdf', _pdfBytes.length, _pdfBytes));
  final manifest = {
    'format': 'DocsGridBackup', 'version': 1, 'backupType': databaseOnly ? 'database' : 'full',
    'backupId': 'restore-test', 'databaseSchemaVersion': 9,
    'createdAt': '2026-01-01T00:00:00Z',
    'tables': {for (final entry in rows.entries) entry.key: entry.value.length},
    'metadataFiles': metadataFiles,
    'files': databaseOnly ? <Map<String, Object?>>[] : [{
      'documentId': 'document-1', 'entry': 'pdfs/policy.pdf',
      'sha256': _pdfHash, 'originalName': 'Policy.pdf',
    }],
  };
  final manifestBytes = Uint8List.fromList(utf8.encode(jsonEncode(manifest)));
  archive.addFile(ArchiveFile('manifest.json', manifestBytes.length, manifestBytes));
  final encoded = ZipEncoder().encode(archive);
  final file = File('${directory.path}/$fileName');
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

Future<void> _insertExistingDocument(Database db, {String id = 'document-1'}) async {
  await db.insert('documents', {
    'id': id, 'name': 'Existing policy', 'mime_type': 'application/pdf',
    'size_bytes': 4, 'sha256': List.filled(64, 'f').join(),
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
  late Database db;
  late DocumentToolsService service;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('docsgrid_restore_integration_');
    appDocuments = Directory('${temp.path}/app_documents');
    await appDocuments.create(recursive: true);
    messenger.setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') return appDocuments.path;
      if (call.method == 'getTemporaryDirectory') return temp.path;
      throw MissingPluginException('Unexpected path_provider method: ${call.method}');
    });
    db = await _openV7Database(temp);
    service = DocumentToolsService(database: AppDatabase.forTesting(() async => db));
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathChannel, null);
    await db.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

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

  test('Automatic recovery prefers an older full backup over a newer database-only backup', () async {
    final backupDirectory = Directory('${appDocuments.path}/DocsGrid/Backups');
    await backupDirectory.create(recursive: true);
    final full = await _makeBackup(
      backupDirectory,
      fileName: 'DocsGrid_full.zip',
    );
    final databaseOnly = await _makeBackup(
      backupDirectory,
      databaseOnly: true,
      fileName: 'DocsGrid_database.zip',
    );
    // The database-only archive is deliberately newer, reproducing the
    // user's two-archive setup where the previous implementation chose it.
    await full.setLastModified(DateTime(2026, 11, 13));
    await databaseOnly.setLastModified(DateTime(2026, 11, 14));

    final restored = await service.restoreNewestPortableBackup(
      confirm: (_) async => true,
    );

    expect(restored, 1);
    final document = (await db.query('documents')).single;
    final restoredPdf = File(document['storage_uri'] as String);
    expect(await restoredPdf.exists(), isTrue);
    expect(await restoredPdf.length(), _pdfBytes.length);
  });

  test('Merge restores PDFs and remaps an existing document ID collision', () async {
    await _insertExistingDocument(db);
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
    await _insertExistingDocument(db);
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
    final restoreRoot = Directory('${appDocuments.path}/DocsGrid/Restored');
    if (await restoreRoot.exists()) {
      final remaining = await restoreRoot.list().toList();
      expect(
        remaining,
        isEmpty,
        reason: 'Failed restores must remove empty fallback parent directories as well as staged files.',
      );
    }
  });
}
