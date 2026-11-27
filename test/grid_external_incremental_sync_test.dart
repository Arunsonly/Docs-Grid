import 'dart:io';
import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/core/storage/grid_external_index.dart';
import 'package:docs_grid/core/storage/portable_snapshot_events.dart';
import 'package:docs_grid/features/documents/data/document_repository.dart';
import 'package:docs_grid/features/folders/data/folder_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  const stamp = '2026-11-26T00:00:00Z';
  final hash = List.filled(64, 'a').join();
  const folder = 'folder-a';
  const oldPath = '/storage/emulated/0/DocsGrid/My Files/Folders/Policy/old.pdf';
  const newPath = '/storage/emulated/0/DocsGrid/My Files/Folders/Policy/new.pdf';
  late Database db;
  late GridExternalIndex index;
  late DocumentRepository documents;
  late FolderRepository folders;
  late Map<String, String> states;
  late Map<String, String> hashes;
  late List<String> probes;
  late List<String> hashed;

  setUp(() async {
    db = await AppDatabase.instance.openProductionSchemaForTesting(inMemoryDatabasePath);
    final appDb = AppDatabase.forTesting(() async => db);
    index = GridExternalIndex(db);
    documents = DocumentRepository(database: appDb);
    folders = FolderRepository(database: appDb);
    states = {};
    hashes = {};
    probes = [];
    hashed = [];
    await db.insert('folders', {'id': folder, 'name': 'Policy', 'created_at': stamp, 'updated_at': stamp});
    await db.insert('folders', {'id': 'intentionally-empty', 'name': 'Empty', 'created_at': stamp, 'updated_at': stamp});
  });

  tearDown(() async => db.close());

  Future<void> add(String id, String path, {String? digest}) async {
    await db.insert('documents', {
      'id': id, 'name': 'Policy $id', 'folder_id': folder,
      'storage_uri': Uri.file(path).toString(), 'size_bytes': 100,
      'sha256': digest ?? hash, 'is_favorite': 1,
      'metadata_json': '{"note":"preserve me"}',
      'created_at': stamp, 'updated_at': stamp,
    });
  }

  Future<GridExternalResult> apply(List<String> paths) => index.applyPaths(
    paths,
    probe: (path) async {
      probes.add(path);
      return {'state': states[path] ?? 'unknown', 'uri': Uri.file(path).toString(),
        'size': 100, 'modified': 42};
    },
    digest: (path) async {
      hashed.add(path);
      return hashes[path] ?? hash;
    },
  );

  test('delete changes only derived visibility; restore preserves identity and metadata', () async {
    await add('original', oldPath);
    final original = (await db.query('documents', where: 'id = ?', whereArgs: ['original'])).single;
    states[oldPath] = 'missing';
    final change = await apply([oldPath]);
    expect(change.affected, {folder, null});
    expect(await documents.countInFolder(folder), 0);
    expect((await documents.listInFolderPage(folder)).records, isEmpty);
    expect(await documents.list(query: 'Policy'), isEmpty);
    final root = await folders.childrenOf(null);
    expect(root.singleWhere((f) => f.id == folder).externallyEmptied, isTrue);
    expect(root.singleWhere((f) => f.id == 'intentionally-empty').externallyEmptied, isFalse);
    expect((await db.query('documents', where: 'id = ?', whereArgs: ['original'])).single, original);
    expect(hashed, isEmpty);
    // A replacement at the same name must not inherit the original metadata.
    states[oldPath] = 'available';
    hashes[oldPath] = List.filled(64, 'b').join();
    expect((await apply([oldPath])).affected, isEmpty);
    expect(await documents.countInFolder(folder), 0);
    hashes[oldPath] = hash;
    await apply([oldPath]);
    expect(await documents.countInFolder(folder), 1);
    expect((await documents.listInFolder(folder)).single.id, 'original');
    expect((await db.query('documents', where: 'id = ?', whereArgs: ['original'])).single, original);
    expect((await folders.childrenOf(null)).singleWhere((f) => f.id == folder).externallyEmptied, isFalse);
  });

  test('external deletion and reappearance update Recent without erasing open history', () async {
    await add('original', oldPath);
    await db.update('documents', {'last_opened_at': stamp},
        where: 'id = ?', whereArgs: ['original']);
    expect((await documents.recentActivity()).single.id, 'original');
    expect((await documents.listPage(recentOnly: true)).items.single.id, 'original');
    var uiEvents = 0;
    var backupEvents = 0;
    final ui = PortableSnapshotEvents.libraryChanges.listen((_) => uiEvents++);
    final backup = PortableSnapshotEvents.changes.listen((_) => backupEvents++);
    addTearDown(ui.cancel);
    addTearDown(backup.cancel);
    states[oldPath] = 'missing';
    final deleted = await apply([oldPath]);
    PortableSnapshotEvents.notifyGridAvailabilityChanged(deleted.affected);
    expect(await documents.recentActivity(), isEmpty);
    expect((await documents.listPage(recentOnly: true)).items, isEmpty);
    expect(await documents.list(recentOnly: true), isEmpty);
    expect((await db.query('documents')).single['last_opened_at'], stamp);
    states[oldPath] = 'available';
    final restored = await apply([oldPath]);
    PortableSnapshotEvents.notifyGridAvailabilityChanged(restored.affected);
    expect((await documents.recentActivity()).single.id, 'original');
    expect((await documents.listPage(recentOnly: true)).items.single.id, 'original');
    expect(uiEvents, 2);
    expect(backupEvents, 0);
  });

  test('cold local reconciliation skips an unchanged directory and repairs missed delete and restore', () async {
    await add('original', oldPath);
    final directory = File(oldPath).parent.path;
    var stampNow = 'one';
    var available = true;
    var reads = 0;
    var skips = 0;
    Future<Map<String, Object?>> snapshot(String uri, String? known) async {
      expect(uri, directory);
      if (known == stampNow) {
        skips++;
        return {'complete': true, 'unchanged': true, 'stamp': stampNow};
      }
      reads++;
      return {'complete': true, 'stamp': stampNow, 'entries': [
        if (available) {'uri': Uri.file(oldPath).toString(), 'name': 'old.pdf',
          'size': 100, 'sizeKnown': true, 'lastModified': 42},
      ]};
    }
    Future<GridExternalResult> reconcile() => index.reconcileDirectory(
      directory: directory, folderId: folder, snapshot: snapshot,
      digest: (path) async { hashed.add(path); return hash; });
    expect((await reconcile()).affected, isEmpty);
    expect((await reconcile()).affected, isEmpty);
    expect(reads, 1);
    expect(skips, 1);
    stampNow = 'two';
    available = false;
    expect((await reconcile()).affected, {folder, null});
    expect(await documents.recentActivity(), isEmpty);
    expect(hashed, isEmpty);
    stampNow = 'three';
    available = true;
    expect((await reconcile()).affected, {folder, null});
    expect((await documents.recentActivity()).single.id, 'original');
    expect(hashed, [oldPath]);
  });

  test('SAF scoped snapshots hide only verified absent PDFs and preserve stable-ID renames', () async {
    const directory = 'content://provider/tree/root/document/folder';
    const uri = 'content://provider/tree/root/document/pdf-id';
    await add('original', oldPath);
    await db.update('documents', {'storage_uri': uri, 'name': 'old'},
        where: 'id = ?', whereArgs: ['original']);
    await add('unrelated', newPath);
    var name = 'old.pdf';
    var available = true;
    var complete = true;
    Future<Map<String, Object?>> snapshot(String requested, String? known) async {
      expect(requested, directory);
      return {'complete': complete, 'stamp': '', 'entries': [
        if (available) {'uri': uri, 'name': name, 'size': 100,
          'sizeKnown': true, 'lastModified': 42},
      ]};
    }
    Future<GridExternalResult> reconcile() => index.reconcileDirectory(
      directory: directory, folderId: folder, snapshot: snapshot,
      digest: (path) async { hashed.add(path); return hash; });
    await reconcile();
    available = false;
    complete = false;
    expect((await reconcile()).affected, isEmpty);
    expect(await documents.countInFolder(folder), 2);
    complete = true;
    expect((await reconcile()).affected, {folder, null});
    expect(await documents.countInFolder(folder), 1);
    expect((await documents.recentActivity()).single.id, 'unrelated');
    available = true;
    await reconcile();
    expect(await documents.countInFolder(folder), 2);
    name = 'renamed.pdf';
    final renamed = await reconcile();
    expect(renamed.renamed, isTrue);
    final row = (await db.query('documents', where: 'id = ?', whereArgs: ['original'])).single;
    expect(row['storage_uri'], uri);
    expect(row['name'], 'renamed');
    expect(row['sha256'], hash);
    expect((await reconcile()).renamed, isFalse);
  });

  test('permission or unknown errors never hide a PDF', () async {
    await add('original', oldPath);
    states[oldPath] = 'unknown';
    final result = await apply([oldPath]);
    expect(result.affected, isEmpty);
    expect(await documents.countInFolder(folder), 1);
    expect(hashed, isEmpty);
    expect(await db.query('grid_external_missing'), isEmpty);
  });

  test('same-folder rename requires matching hash and absent original; id is preserved', () async {
    await add('original', oldPath);
    states[oldPath] = 'missing';
    states[newPath] = 'available';
    final result = await apply([newPath, oldPath]);
    expect(result.renamed, isTrue);
    final row = (await db.query('documents', where: 'id = ?', whereArgs: ['original'])).single;
    expect(row['storage_uri'], Uri.file(newPath).toString());
    expect(row['name'], 'new');
    expect(row['folder_id'], folder);
    expect(row['sha256'], hash);
    expect(row['deleted_at'], isNull);
    expect(row['is_favorite'], 1);
    expect(row['metadata_json'], '{"note":"preserve me"}');
    expect(await documents.countInFolder(folder), 1);
    expect(await db.query('grid_external_missing'), isEmpty);
    expect(await db.query('history', where: 'document_id = ?', whereArgs: ['original']), hasLength(1));
  });

  test('an unrelated PDF cannot be relinked or silently imported', () async {
    await add('original', oldPath);
    states[oldPath] = 'missing';
    states[newPath] = 'available';
    hashes[newPath] = List.filled(64, 'c').join();
    final result = await apply([oldPath, newPath]);
    expect(result.renamed, isFalse);
    expect(await documents.countInFolder(folder), 0);
    expect(await db.query('documents'), hasLength(1));
  });

  test('4000-PDF folder: only the changed PDF is probed and no bytes are hashed for delete', () async {
    final batch = db.batch();
    for (var i = 0; i < 4000; i++) {
      batch.insert('documents', {
        'id': 'pdf-$i', 'name': 'PDF $i', 'folder_id': folder,
        'storage_uri': Uri.file('/storage/emulated/0/DocsGrid/My Files/Folders/Policy/$i.pdf').toString(),
        'size_bytes': 100, 'created_at': stamp, 'updated_at': stamp,
      });
    }
    await batch.commit(noResult: true);
    const changed = '/storage/emulated/0/DocsGrid/My Files/Folders/Policy/1200.pdf';
    states[changed] = 'missing';
    await apply([changed]);
    expect(probes, [changed, changed]);
    expect(hashed, isEmpty);
    final plan = await db.rawQuery(
      'EXPLAIN QUERY PLAN SELECT * FROM documents INDEXED BY idx_grid_storage_uri '
      'WHERE deleted_at IS NULL AND storage_uri IN (?, ?)',
      [changed, Uri.file(changed).toString()],
    );
    expect(plan.map((r) => r['detail']).join(' '), contains('idx_grid_storage_uri'));
    expect(await folders.countDirectChildren(null), 2);
    expect(await documents.countInFolder(folder), 3999);
    expect(await db.query('grid_external_missing'), hasLength(1));
    expect((await db.rawQuery('SELECT COUNT(*) AS n FROM documents')).single['n'], 4000);
  });

  test('ordinary app storage locator updates clear stale derived visibility', () async {
    await add('original', oldPath);
    states[oldPath] = 'missing';
    await apply([oldPath]);
    await db.update('documents', {'storage_uri': Uri.file(newPath).toString()},
      where: 'id = ?', whereArgs: ['original']);
    expect(await db.query('grid_external_missing'), isEmpty);
    expect(await documents.countInFolder(folder), 1);
  });

  test('native watcher uses existing folder paths; no PDF directory enumeration', () {
    final source = File('platform/android/MainActivity.kt').readAsStringSync();
    final start = source.indexOf('private fun setGridWatches(');
    final end = source.indexOf('private fun gridSafAllowed(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final watcher = source.substring(start, end);
    expect(watcher, contains('FileObserver(path, gridWatchMask)'));
    expect(watcher, isNot(contains('listFiles(')));
    expect(watcher, isNot(contains('walkTopDown(')));
    final pause = source.substring(source.indexOf('override fun onPause()'), source.indexOf('private fun registerStorageChangeObservers()'));
    expect(pause, isNot(contains('stopGridWatches()')));
  });
}
