import 'dart:convert';
import 'dart:io';

import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/tools/document_tools_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
    expect(DocumentToolsService.snapshotDiagnostics['lastCreationResult'], 'failed');
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
    test('consistent snapshot export of $count document metadata rows', () async {
      final root = await mockSnapshotStorage();
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (var i = 0; i < count; i++) {
          batch.insert('documents', {
            'id': 'snapshot-stress-$i',
            'name': 'Document $i',
            'mime_type': 'application/pdf',
            'size_bytes': 0,
            'storage_uri': null,
            'sha256': null,
            'created_at': '2026-01-01T00:00:00Z',
            'updated_at': '2026-01-01T00:00:00Z',
          });
        }
        await batch.commit(noResult: true);
      });
      final name = await service.createPortableMetadataSnapshot();
      final snapshot = Directory('${root.path}/$name');
      expect(await snapshot.exists(), isTrue);
      final manifest = jsonDecode(await File('${snapshot.path}/manifest.json').readAsString()) as Map;
      expect((manifest['tables'] as Map)['documents'], count);
      expect(DocumentToolsService.snapshotDiagnostics['lastCreationResult'], 'verified');
      expect(await service.createPortableMetadataSnapshot(), name);
    });
  }

  test('legacy snapshot without operation ownership marker remains untouched', () async {
    final root = await mockSnapshotStorage();
    final oldName = await service.createPortableMetadataSnapshot();
    final legacy = Directory('${root.path}/$oldName');
    await File('${legacy.path}/operation.json').delete();
    for (var i = 0; i < 10; i++) {
      await db.insert('folders', {'id': 'test-folder-$i', 'name': 'Legacy Test $i',
        'created_at': '2026-01-01', 'updated_at': '2026-01-01'});
      await service.createPortableMetadataSnapshot();
    }
    expect(await File('${legacy.path}/manifest.json').exists(), isTrue);
  });

}
