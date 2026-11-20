import 'dart:async';

import 'package:flutter/services.dart';
import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/core/storage/portable_snapshot_events.dart';
import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late FolderRepository repository;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE folders (
        id TEXT PRIMARY KEY, name TEXT NOT NULL,
        parent_id TEXT, storage_uri_or_relative_path TEXT,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        deleted_at TEXT, sort_order INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('CREATE TABLE documents (id TEXT, folder_id TEXT, deleted_at TEXT)');
    repository = FolderRepository(database: AppDatabase.forTesting(() async => db));

    final batch = db.batch();
    for (var i = 0; i < 55; i++) {
      batch.insert('folders', {
        'id': 'folder-$i',
        'name': 'Folder ${i.toString().padLeft(3, '0')}',
        'sort_order': i,
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      });
    }
    batch.insert('folders', {
      'id': 'nested', 'name': 'Nested', 'parent_id': 'folder-0',
      'sort_order': 0,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    });
    batch.insert('folders', {
      'id': 'deleted', 'name': 'Deleted', 'deleted_at': '2026-11-01',
      'sort_order': 56,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    });
    await batch.commit(noResult: true);
  });

  tearDown(() async {
    await db.close();
  });

  test('background prefetch is bounded but normal interactive childrenOf stays complete', () async {
    final preview = await repository.childrenOf(null, previewLimit: 16);
    expect(preview, hasLength(16));
    expect(preview.first.name, 'Folder 000');
    expect(preview.last.name, 'Folder 015');

    // Old APIs are unaffected: tapping a folder still lists every child.
    final interactive = await repository.childrenOf(null);
    expect(interactive, hasLength(55));
    expect(interactive.last.name, 'Folder 054');
    expect(await repository.countDirectChildren(null), 55);
    expect(await repository.countDirectChildren('folder-0'), 1);
    expect(await repository.childrenOf('folder-0'), hasLength(1));
  });

  test('childrenOf validates providers in bounded parallel batches, preserving SQLite order', () async {
    const channel = MethodChannel('docsgrid/storage');
    final messenger = TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    for (var i = 0; i < 8; i++) {
      await db.update('folders', {
        'storage_uri_or_relative_path': 'content://tree/provider/$i',
      }, where: 'id = ?', whereArgs: ['folder-$i']);
    }
    var active = 0;
    var maximumActive = 0;
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'listDirectory') {
        throw PlatformException(code: 'UNEXPECTED_METHOD');
      }
      active++;
      calls++;
      if (active > maximumActive) maximumActive = active;
      await Future<void>.delayed(const Duration(milliseconds: 8));
      active--;
      if (call.arguments['uri'] == 'content://tree/provider/3') {
        throw PlatformException(code: 'NOT_FOUND', message: 'Removed outside app');
      }
      return <Map<String, Object?>>[];
    });
    final folders = await repository.childrenOf(null, previewLimit: 10);
    expect(maximumActive, greaterThan(1));
    expect(maximumActive, lessThanOrEqualTo(3));
    expect(calls, 8);
    expect(folders.map((folder) => folder.id), [
      'folder-0', 'folder-1', 'folder-2', 'folder-4',
      'folder-5', 'folder-6', 'folder-7', 'folder-8',
      'folder-9',
    ]);
    // Read-only checks NEVER delete even a missing folder's DB record.
    expect(await repository.countDirectChildren(null), 55);
  });

  test('provider permission errors still propagate instead of showing a false empty folder', () async {
    const channel = MethodChannel('docsgrid/storage');
    final messenger = TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await db.update('folders', {
      'storage_uri_or_relative_path': 'content://tree/provider/0',
    }, where: 'id = ?', whereArgs: ['folder-0']);
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'PERMISSION_DENIED', message: 'Grant revoked');
    });
    await expectLater(
      repository.childrenOf(null, previewLimit: 2),
      throwsA(isA<PlatformException>().having(
        (error) => error.code, 'code', 'PERMISSION_DENIED',
      )),
    );
    expect(await repository.countDirectChildren(null), 55);
  });

  test('a provider that refuses parallel calls gets the legacy sequential fallback', () async {
    const channel = MethodChannel('docsgrid/storage');
    final messenger = TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    for (var i = 0; i < 6; i++) {
      await db.update('folders', {
        'storage_uri_or_relative_path': 'content://tree/limited/$i',
      }, where: 'id = ?', whereArgs: ['folder-$i']);
    }
    var active = 0;
    var attemptedInParallel = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      active++;
      final concurrent = active > 1;
      await Future<void>.delayed(const Duration(milliseconds: 6));
      active--;
      if (concurrent) {
        attemptedInParallel = true;
        throw PlatformException(code: 'BUSY', message: 'Provider serial only');
      }
      return <Map<String, Object?>>[];
    });
    final result = await repository.childrenOf(null, previewLimit: 6);
    expect(attemptedInParallel, isTrue);
    expect(result.map((item) => item.id), [
      'folder-0', 'folder-1', 'folder-2',
      'folder-3', 'folder-4', 'folder-5',
    ]);
  });

  test('root reorder only invalidates root preview and retains its 55 children', () async {
    final changes = <GridFolderChange>[];
    final sub = PortableSnapshotEvents.gridPreviewChanges.listen(changes.add);
    addTearDown(sub.cancel);
    final reversed = [
      for (var i = 54; i >= 0; i--) 'folder-$i',
    ];
    await repository.reorderChildren(null, reversed);
    expect(changes, hasLength(1));
    expect(changes.single.affects(null), isTrue);
    expect(changes.single.affects('folder-5'), isFalse);
    expect((await repository.childrenOf(null)).first.id, 'folder-54');
    expect(await repository.countDirectChildren(null), 55);
  });

  test('folder move invalidates only source and destination parent previews', () async {
    final changes = <GridFolderChange>[];
    final sub = PortableSnapshotEvents.gridPreviewChanges.listen(changes.add);
    addTearDown(sub.cancel);
    await repository.moveManyToParent(['folder-0'], 'folder-1');
    expect(changes, hasLength(1));
    final change = changes.single;
    expect(change.invalidateAll, isFalse);
    expect(change.affects(null), isTrue);
    expect(change.affects('folder-1'), isTrue);
    expect(change.affects('folder-2'), isFalse);
    expect(await repository.countDirectChildren(null), 54);
    expect(await repository.countDirectChildren('folder-1'), 1);
  });

  test('bad prefetch bounds are rejected before any provider read', () async {
    await expectLater(repository.childrenOf(null, previewLimit: 0),
        throwsArgumentError);
    await expectLater(repository.childrenOf(null, previewLimit: 25),
        throwsArgumentError);
    expect(await repository.childrenOf(null, previewLimit: 1), hasLength(1));
  });
}
