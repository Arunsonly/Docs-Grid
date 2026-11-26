import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../database/app_database.dart';
import 'portable_snapshot_events.dart';
import 'storage_location_service.dart';
import 'storage_migration_gate.dart';

/// Local, rebuildable availability index; no document is trashed or removed.
class GridExternalIndex {
  GridExternalIndex(this.db);
  final Database db;
  static final _schema = Expando<Future<void>>();
  static const _table = 'grid_external_missing';

  static Future<void> ensureSchema(Database db) async {
    final pending = _schema[db];
    if (pending != null) return pending;
    final creation = db.transaction((txn) async {
      await txn.execute('CREATE INDEX IF NOT EXISTS idx_grid_storage_uri ON documents(storage_uri)');
      await txn.execute('CREATE TABLE IF NOT EXISTS $_table (document_id TEXT PRIMARY KEY, storage_uri TEXT NOT NULL)');
      await txn.execute('CREATE TRIGGER IF NOT EXISTS grid_external_clear_insert AFTER INSERT ON documents BEGIN DELETE FROM $_table WHERE document_id = NEW.id; END');
      await txn.execute('CREATE TRIGGER IF NOT EXISTS grid_external_clear_update AFTER UPDATE OF storage_uri, deleted_at ON documents WHEN OLD.storage_uri IS NOT NEW.storage_uri OR OLD.deleted_at IS NOT NEW.deleted_at BEGIN DELETE FROM $_table WHERE document_id = NEW.id; END');
      await txn.execute('CREATE TRIGGER IF NOT EXISTS grid_external_clear_delete AFTER DELETE ON documents BEGIN DELETE FROM $_table WHERE document_id = OLD.id; END');
    });
    _schema[db] = creation;
    try { await creation; } catch (_) { _schema[db] = null; rethrow; }
  }

  static String visible(String alias) =>
      'NOT EXISTS (SELECT 1 FROM $_table gm WHERE gm.document_id = $alias.id AND gm.storage_uri = $alias.storage_uri)';

  static String? localPath(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      if (value.startsWith('/')) return p.normalize(value);
      final uri = Uri.parse(value);
      if (uri.scheme == 'file') return p.normalize(uri.toFilePath());
    } catch (_) {}
    return null;
  }

  Future<List<Map<String, Object?>>> _at(DatabaseExecutor executor, String path, String? nativeUri) {
    final locations = <String>{path, Uri.file(path).toString(), if (nativeUri != null) nativeUri}.toList();
    return executor.query('documents',
      where: 'deleted_at IS NULL AND storage_uri IN (${List.filled(locations.length, '?').join(',')})',
      whereArgs: locations);
  }

  Future<bool> _busy(DatabaseExecutor txn, Map<String, Object?> row) async {
    final keys = <String>['document:${row['id']}'];
    String? folder = row['folder_id'] as String?;
    final seen = <String>{};
    while (folder != null) {
      if (!seen.add(folder) || seen.length > 512) return true;
      keys.add('folder:$folder');
      final rows = await txn.query('folders', columns: ['parent_id'], where: 'id = ?', whereArgs: [folder], limit: 1);
      if (rows.isEmpty) return true;
      folder = rows.single['parent_id'] as String?;
    }
    final locks = await txn.query('file_operation_journal', columns: ['resource_key'],
      where: "state != 'completed' AND resource_key IN (${List.filled(keys.length, '?').join(',')})", whereArgs: keys, limit: 1);
    return locks.isNotEmpty;
  }

  Future<void> _affected(DatabaseExecutor txn, String? folder, Set<String?> affected) async {
    affected.add(folder);
    if (folder == null) return;
    final rows = await txn.query('folders', columns: ['parent_id'], where: 'id = ?', whereArgs: [folder], limit: 1);
    if (rows.isNotEmpty) affected.add(rows.single['parent_id'] as String?);
  }

  Future<Map<String, Object?>> _safeProbe(String path, Future<Map<String, Object?>> Function(String) probe) async {
    try { return await probe(path); } catch (_) { return const {'state': 'unknown'}; }
  }

  /// Only the changed paths are probed. Unknown/permission failures are no-ops.
  /// A rename requires a unique missing row with the same hash in the same directory.
  Future<GridExternalResult> applyPaths(Iterable<String> paths, {
    required Future<Map<String, Object?>> Function(String) probe,
    required Future<String> Function(String) digest,
  }) async {
    await ensureSchema(db);
    final affected = <String?>{};
    var renamed = false;
    final observations = <String, Map<String, Object?>>{};
    for (final path in paths.toSet()) {
      if (localPath(path) != path || !path.toLowerCase().endsWith('.pdf')) continue;
      observations[path] = await _safeProbe(path, probe);
    }
    for (final item in observations.entries) {
      if (item.value['state'] != 'missing') continue;
      await db.transaction((txn) async {
        for (final row in await _at(txn, item.key, item.value['uri'] as String?)) {
          if (await _busy(txn, row)) continue;
          final id = row['id'] as String;
          final old = await txn.query(_table, where: 'document_id = ?', whereArgs: [id], limit: 1);
          if (old.isNotEmpty && old.single['storage_uri'] == row['storage_uri']) continue;
          await txn.insert(_table, {'document_id': id, 'storage_uri': row['storage_uri']}, conflictAlgorithm: ConflictAlgorithm.replace);
          await _affected(txn, row['folder_id'] as String?, affected);
        }
      });
    }
    for (final item in observations.entries) {
      if (item.value['state'] != 'available') continue;
      final nativeUri = item.value['uri'] as String?;
      final exact = await _at(db, item.key, nativeUri);
      if (exact.length > 1) continue;
      Map<String, Object?>? candidate;
      if (exact.length == 1) {
        final row = exact.single;
        final hidden = await db.query(_table, where: 'document_id = ? AND storage_uri = ?', whereArgs: [row['id'], row['storage_uri']], limit: 1);
        if (hidden.isEmpty) continue;
        candidate = row;
      } else {
        if ((await db.query(_table, columns: ['document_id'], limit: 1)).isEmpty) continue;
      }
      String hash;
      try { hash = await digest(item.key); } catch (_) { continue; }
      if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash)) continue;
      if (candidate == null) {
        final matches = await db.rawQuery('SELECT d.* FROM documents d INNER JOIN $_table gm ON gm.document_id = d.id AND gm.storage_uri = d.storage_uri WHERE d.deleted_at IS NULL AND d.sha256 = ?', [hash]);
        final sameFolder = matches.where((row) {
          final previous = localPath(row['storage_uri'] as String?);
          return previous != null && p.dirname(previous) == p.dirname(item.key);
        }).toList();
        if (sameFolder.length != 1) continue;
        candidate = sameFolder.single;
      }
      final row = candidate;
      if (row == null || row['sha256'] != hash) continue;
      final previous = localPath(row['storage_uri'] as String?);
      if (previous == null) continue;
      final isRename = previous != item.key;
      if (isRename && (await _safeProbe(previous, probe))['state'] != 'missing') continue;
      final latest = await _safeProbe(item.key, probe);
      if (latest['state'] != 'available' || latest['size'] != item.value['size'] || latest['modified'] != item.value['modified']) continue;
      await db.transaction((txn) async {
        if (await _busy(txn, row)) return;
        final live = await txn.query('documents', where: 'id = ? AND deleted_at IS NULL AND storage_uri = ? AND sha256 = ?', whereArgs: [row['id'], row['storage_uri'], hash], limit: 1);
        if (live.isEmpty) return;
        final hidden = await txn.query(_table, where: 'document_id = ? AND storage_uri = ?', whereArgs: [row['id'], row['storage_uri']], limit: 1);
        if (hidden.isEmpty) return;
        if (isRename) {
          if ((await _at(txn, item.key, nativeUri)).isNotEmpty) return;
          final name = p.basenameWithoutExtension(item.key);
          if (name.isEmpty) return;
          final now = DateTime.now().toUtc().toIso8601String();
          await txn.update('documents', {'name': name, 'storage_uri': nativeUri ?? Uri.file(item.key).toString(), 'relative_path': null, 'updated_at': now}, where: 'id = ?', whereArgs: [row['id']]);
          await txn.insert('history', {'id': const Uuid().v4(), 'document_id': row['id'], 'action': 'renamed', 'details_json': jsonEncode({'from': row['name'], 'to': name, 'source': 'external_file_manager'}), 'created_at': now});
          renamed = true;
        }
        await txn.delete(_table, where: 'document_id = ?', whereArgs: [row['id']]);
        await _affected(txn, live.single['folder_id'] as String?, affected);
      });
    }
    return GridExternalResult(affected, renamed);
  }
}

class GridExternalResult {
  GridExternalResult(this.affected, this.renamed);
  final Set<String?> affected;
  final bool renamed;
}

/// A single app-lifetime native observer; no periodic storage scan.
class GridExternalSync {
  static const _channel = MethodChannel('docsgrid/grid_external');
  static const _events = EventChannel('docsgrid/grid_external_events');
  StreamSubscription<dynamic>? _subscription;
  StreamSubscription<GridFolderChange>? _librarySubscription;
  final _paths = <String>{};
  Timer? _debounce, _watchDebounce;
  bool _working = false, _watching = false, _watchPending = false, _disposed = false;

  void start() {
    if (!Platform.isAndroid || _disposed || _subscription != null) return;
    _subscription = _events.receiveBroadcastStream().listen((dynamic event) {
      if (_disposed || event is! String) return;
      _paths.add(event);
      _scheduleDrain();
    }, onError: (Object _) {});
    _librarySubscription = PortableSnapshotEvents.gridPreviewChanges.listen((change) {
      if (!change.precise && (change.affectedFolderIds == null || change.affectedFolderIds!.isNotEmpty)) refreshWatches();
    });
    refreshWatches();
  }

  void refreshWatches() {
    if (!Platform.isAndroid || _disposed || _subscription == null) return;
    _watchPending = true;
    _watchDebounce?.cancel();
    _watchDebounce = Timer(const Duration(milliseconds: 250), () => unawaited(_refresh()));
  }

  Future<void> _refresh() async {
    if (_disposed || _watching || !_watchPending) return;
    _watching = true;
    _watchPending = false;
    try {
      final db = await AppDatabase.instance.database;
      final rows = await db.query('folders', columns: ['storage_uri_or_relative_path'], where: 'deleted_at IS NULL');
      final directories = rows.map((r) => GridExternalIndex.localPath(r['storage_uri_or_relative_path'] as String?)).whereType<String>().toSet().toList();
      if (!_disposed) await _channel.invokeMethod<dynamic>('setWatches', directories);
    } catch (_) {
      // Permission/provider failures do not mutate any record.
    } finally {
      _watching = false;
      if (_watchPending && !_disposed) refreshWatches();
    }
  }

  void _scheduleDrain() {
    if (_disposed || _working) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => unawaited(_drain()));
  }

  Future<void> _drain() async {
    if (_disposed || _working || _paths.isEmpty) return;
    _working = true;
    final paths = _paths.take(48).toList();
    _paths.removeAll(paths);
    try {
      await StorageMigrationGate.waitUntilReady();
      final db = await AppDatabase.instance.database;
      final result = await GridExternalIndex(db).applyPaths(paths,
        probe: (path) async => (await _channel.invokeMapMethod<String, Object?>('probe', path)) ?? const {'state': 'unknown'},
        digest: (path) => StorageLocationService.instance.sha256Pdf(Uri.file(path).toString()));
      if (result.affected.isNotEmpty) {
        if (result.renamed) {
          PortableSnapshotEvents.notifyDataChanged(affectedFolderIds: result.affected, preciseGridFolders: true);
        } else {
          PortableSnapshotEvents.notifyGridPreviewChanged(result.affected, precise: true);
        }
      }
    } catch (_) {
      // No destructive fallback; retain original records.
    } finally {
      _working = false;
      if (_paths.isNotEmpty && !_disposed) _scheduleDrain();
    }
  }

  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _watchDebounce?.cancel();
    _subscription?.cancel();
    _librarySubscription?.cancel();
    _paths.clear();
  }
}
