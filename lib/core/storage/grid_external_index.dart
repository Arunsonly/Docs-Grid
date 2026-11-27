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
  static const _checkpoints = 'grid_external_directory_checkpoints';

  static Future<void> ensureSchema(Database db) async {
    final pending = _schema[db];
    if (pending != null) return pending;
    final creation = db.transaction((txn) async {
      final columns = (await txn.rawQuery('PRAGMA table_info(documents)')).map((row) => row['name']).toSet();
      if (columns.contains('storage_uri')) {
        await txn.execute('CREATE INDEX IF NOT EXISTS idx_grid_storage_uri ON documents(storage_uri)');
      }
      await txn.execute('CREATE TABLE IF NOT EXISTS $_table (document_id TEXT PRIMARY KEY, storage_uri TEXT NOT NULL)');
      await txn.execute('CREATE TABLE IF NOT EXISTS $_checkpoints (directory_uri TEXT PRIMARY KEY, stamp TEXT NOT NULL, names_json TEXT NOT NULL)');
      await txn.execute('CREATE TRIGGER IF NOT EXISTS grid_external_clear_insert AFTER INSERT ON documents BEGIN DELETE FROM $_table WHERE document_id = NEW.id; END');
      final fields = columns.contains('storage_uri') ? 'storage_uri, deleted_at' : 'deleted_at';
      final locatorChange = columns.contains('storage_uri') ? 'OLD.storage_uri IS NOT NEW.storage_uri OR ' : '';
      await txn.execute('CREATE TRIGGER IF NOT EXISTS grid_external_clear_update AFTER UPDATE OF $fields ON documents WHEN ${locatorChange}OLD.deleted_at IS NOT NEW.deleted_at BEGIN DELETE FROM $_table WHERE document_id = NEW.id; END');
      await txn.execute('CREATE TRIGGER IF NOT EXISTS grid_external_clear_delete AFTER DELETE ON documents BEGIN DELETE FROM $_table WHERE document_id = OLD.id; END');
    });
    _schema[db] = creation;
    try { await creation; } catch (_) { _schema[db] = null; rethrow; }
  }

  static String visible(String alias) =>
      'NOT EXISTS (SELECT 1 FROM $_table gm WHERE gm.document_id = $alias.id)';

  static String? localPath(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      if (value.startsWith('/')) return p.normalize(value);
      final uri = Uri.parse(value);
      if (uri.scheme == 'file') return p.normalize(uri.toFilePath());
    } catch (_) {}
    return null;
  }

  static String? locator(String? value) {
    final local = localPath(value);
    if (local != null) return local;
    if (value != null && value.startsWith('content://') && Uri.tryParse(value)?.hasAuthority == true) return value;
    return null;
  }

  Future<List<Map<String, Object?>>> _at(DatabaseExecutor executor, String path, String? nativeUri) {
    final locations = <String>{path, if (localPath(path) != null) Uri.file(path).toString(), if (nativeUri != null) nativeUri}.toList();
    // SQLite can otherwise prefer the deleted_at index and walk every
    // active record. Force the exact storage locator index for this lookup.
    return executor.rawQuery(
      'SELECT * FROM documents INDEXED BY idx_grid_storage_uri '
      'WHERE deleted_at IS NULL AND storage_uri IN (${List.filled(locations.length, '?').join(',')})',
      locations);
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
    String? Function(String)? scopeFor,
  }) async {
    String? scope(String path) => scopeFor == null ? (localPath(path) == null ? null : p.dirname(path)) : scopeFor(path);
    await ensureSchema(db);
    final affected = <String?>{};
    var renamed = false;
    final observations = <String, Map<String, Object?>>{};
    for (final path in paths.toSet()) {
      if (locator(path) != path || scope(path) == null || (localPath(path) != null && !path.toLowerCase().endsWith('.pdf'))) continue;
      observations[path] = await _safeProbe(path, probe);
    }
    for (final item in observations.entries) {
      if (item.value['state'] != 'missing') continue;
      if ((await _safeProbe(item.key, probe))['state'] != 'missing') continue;
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
        final changedName = item.value['previousName'] is String && item.value['name'] is String && item.value['previousName'] != item.value['name'];
        if (hidden.isEmpty && !changedName) continue;
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
          final previous = locator(row['storage_uri'] as String?);
          return previous != null && scope(previous) != null && scope(previous) == scope(item.key);
        }).toList();
        if (sameFolder.length != 1) continue;
        candidate = sameFolder.single;
      }
      final row = candidate;
      if (row['sha256'] != hash) continue;
      final previous = locator(row['storage_uri'] as String?);
      if (previous == null || scope(previous) != scope(item.key)) continue;
      final moved = previous != item.key;
      final renamedInPlace = !moved && item.value['previousName'] is String &&
          item.value['name'] is String && item.value['previousName'] != item.value['name'];
      final isRename = moved || renamedInPlace;
      if (moved && (await _safeProbe(previous, probe))['state'] != 'missing') continue;
      final latest = await _safeProbe(item.key, probe);
      if (latest['state'] != 'available' || latest['size'] != item.value['size'] || latest['modified'] != item.value['modified']) continue;
      await db.transaction((txn) async {
        if (await _busy(txn, row)) return;
        final live = await txn.query('documents', where: 'id = ? AND deleted_at IS NULL AND storage_uri = ? AND sha256 = ?', whereArgs: [row['id'], row['storage_uri'], hash], limit: 1);
        if (live.isEmpty) return;
        final hidden = await txn.query(_table, where: 'document_id = ? AND storage_uri = ?', whereArgs: [row['id'], row['storage_uri']], limit: 1);
        if (hidden.isEmpty && !renamedInPlace) return;
        if (isRename) {
          if (moved && (await _at(txn, item.key, nativeUri)).isNotEmpty) return;
          final observedName = item.value['name'] as String?;
          final name = p.basenameWithoutExtension(observedName ?? item.key);
          if (name.isEmpty) return;
          final now = DateTime.now().toUtc().toIso8601String();
          await txn.update('documents', {'name': name, 'storage_uri': nativeUri ?? (localPath(item.key) != null ? Uri.file(item.key).toString() : item.key), 'relative_path': null, 'updated_at': now}, where: 'id = ?', whereArgs: [row['id']]);
          await txn.insert('history', {'id': const Uuid().v4(), 'document_id': row['id'], 'action': 'renamed', 'details_json': jsonEncode({'from': row['name'], 'to': name, 'source': 'external_file_manager'}), 'created_at': now});
          renamed = true;
        }
        await txn.delete(_table, where: 'document_id = ?', whereArgs: [row['id']]);
        await _affected(txn, live.single['folder_id'] as String?, affected);
      });
    }
    return GridExternalResult(affected, renamed);
  }

  /// Reconcile one explicitly known Grid directory, never recurse into device
  /// storage. The provider must attest that its immediate listing is complete.
  /// Local checkpoints skip unchanged directories on cold start. SAF cannot
  /// promise a durable change journal, so a scoped metadata listing is used.
  Future<GridExternalResult> reconcileDirectory({
    required String directory,
    required String? folderId,
    required Future<Map<String, Object?>> Function(String, String?) snapshot,
    required Future<String> Function(String) digest,
    bool force = false,
  }) async {
    await ensureSchema(db);
    final empty = GridExternalResult(<String?>{}, false);
    final checkpoints = await db.query(_checkpoints, where: 'directory_uri = ?', whereArgs: [directory], limit: 1);
    final old = checkpoints.isEmpty ? null : checkpoints.single;
    final first = await snapshot(directory, force ? null : old?['stamp'] as String?);
    if (first['complete'] != true) return empty;
    final stamp = first['stamp'] as String? ?? '';
    if (!force && stamp.isNotEmpty && old?['stamp'] == stamp && first['unchanged'] == true) return empty;
    final raw = first['entries'];
    if (raw is! List || raw.length > 20000) return empty;
    final entries = <String, Map<String, Object?>>{};
    for (final item in raw) {
      if (item is! Map || item['uri'] is! String || item['name'] is! String) return empty;
      final key = locator(item['uri'] as String);
      if (key == null || entries.containsKey(key)) return empty;
      entries[key] = Map<String, Object?>.from(item);
    }
    final rows = await db.query('documents', columns: ['id', 'storage_uri', 'size_bytes'],
      where: folderId == null ? 'deleted_at IS NULL AND folder_id IS NULL' : 'deleted_at IS NULL AND folder_id = ?',
      whereArgs: folderId == null ? null : [folderId]);
    final localDir = localPath(directory);
    final expected = <String, Map<String, Object?>>{};
    for (final row in rows) {
      final key = locator(row['storage_uri'] as String?);
      if (key == null) continue;
      if (localDir != null) {
        if (localPath(key) == null || p.dirname(key) != localDir) continue;
      } else {
        if (!key.startsWith('content://')) continue;
        final uri = Uri.parse(key);
        final parent = Uri.parse(directory);
        final a = uri.pathSegments;
        final b = parent.pathSegments;
        if (uri.authority != parent.authority || a.length < 4 || b.length < 2 ||
            a[0] != 'tree' || b[0] != 'tree' || a[1] != b[1]) continue;
        // An unfiled row can also belong to a previously selected SAF tree.
        // Do not infer absence for an opaque root locator never seen in this directory.
        if (folderId == null && !entries.containsKey(key)) {
          final parentId = b.length >= 4 ? b[3] : b[1];
          final documentId = a[3];
          final prior = old?['names_json'] as String?;
          bool known = false;
          if (prior != null) {
            try {
              final decoded = jsonDecode(prior);
              known = decoded is Map && decoded.containsKey(key);
            } catch (_) {}
          }
          if (!known && !documentId.startsWith('$parentId/')) continue;
        }
      }
      if (expected.containsKey(key)) return empty;
      expected[key] = row;
    }
    final previousNames = <String, String>{};
    if (old != null) {
      try {
        final names = jsonDecode(old['names_json'] as String);
        if (names is Map) {
          for (final item in names.entries) {
            if (item.key is String && item.value is String) previousNames[item.key as String] = item.value as String;
          }
        }
      } catch (_) {}
    }
    final hiddenRows = await db.rawQuery(
      'SELECT gm.document_id FROM $_table gm INNER JOIN documents d ON d.id = gm.document_id '
      'WHERE d.deleted_at IS NULL AND ${folderId == null ? 'd.folder_id IS NULL' : 'd.folder_id = ?'}',
      folderId == null ? [] : [folderId]);
    final hidden = hiddenRows.map((r) => r['document_id']).toSet();
    final changed = <String>{};
    final missingSizes = <int>{};
    for (final item in expected.entries) {
      final entry = entries[item.key];
      if (entry == null) {
        if (!hidden.contains(item.value['id'])) changed.add(item.key);
        final size = item.value['size_bytes'] as int? ?? 0;
        missingSizes.add(size);
      } else if (hidden.contains(item.value['id']) ||
          (previousNames[item.key] != null && previousNames[item.key] != entry['name'])) {
        changed.add(item.key);
      }
    }
    // Only plausible replacement/rename candidates are hashed. Never hash
    // every PDF in a directory merely to detect deletion.
    if (missingSizes.isNotEmpty) {
      final candidates = <String>[];
      for (final item in entries.entries) {
        if (!expected.containsKey(item.key) &&
            (missingSizes.contains(0) || item.value['sizeKnown'] != true ||
             missingSizes.contains(item.value['size']))) candidates.add(item.key);
        if (candidates.length > 32) break;
      }
      // A mass/ambiguous change must not turn a metadata reconciliation
      // into an unbounded full-PDF hashing operation.
      if (candidates.length <= 32) changed.addAll(candidates);
    }
    final all = <String>{...expected.keys, ...entries.keys};
    if (changed.isNotEmpty) {
      // Confirm a second authoritative snapshot matches the first before
      // inferring missing files. An incomplete/loading/changed provider is
      // deferred, not misinterpreted as deletion.
      final second = await snapshot(directory, null);
      if (second['complete'] != true || second['entries'] is! List) return empty;
      final verified = <String, Map<String, Object?>>{};
      for (final item in second['entries'] as List) {
        if (item is! Map || item['uri'] is! String || item['name'] is! String) return empty;
        final key = locator(item['uri'] as String);
        if (key == null || verified.containsKey(key)) return empty;
        verified[key] = Map<String, Object?>.from(item);
      }
      if (entries.length != verified.length || entries.entries.any((entry) {
        final v = verified[entry.key];
        return v == null || v['name'] != entry.value['name'] || v['size'] != entry.value['size'] ||
          v['lastModified'] != entry.value['lastModified'];
      })) return empty;
      final result = await applyPaths(changed, scopeFor: (key) => all.contains(key) ? directory : null,
        probe: (key) async {
          final item = verified[key];
          if (item == null) return expected.containsKey(key) ? {'state': 'missing', 'uri': expected[key]!['storage_uri']} : {'state': 'unknown'};
          return {'state': 'available', 'uri': item['uri'], 'size': item['size'],
            'modified': item['lastModified'], 'name': item['name'], 'previousName': previousNames[key]};
        }, digest: digest);
      // A changed pass deliberately leaves the stamp invalid so a later
      // cold/resume reconciliation can retry locked or unmatched records.
      // Persist only names whose rename was actually accepted by SQLite.
      final names = <String, String>{for (final entry in previousNames.entries) if (expected.containsKey(entry.key)) entry.key: entry.value};
      for (final entry in verified.entries) {
        final name = entry.value['name'] as String;
        if (!changed.contains(entry.key)) {
          if (expected.containsKey(entry.key)) names[entry.key] = name;
          continue;
        }
        // Only changed locators need a fresh SQLite lookup.
        final actual = await _at(db, entry.key, entry.value['uri'] as String?);
        if (actual.length != 1) continue;
        if (previousNames[entry.key] == null ||
            actual.single['name'] == p.basenameWithoutExtension(name)) {
          names[entry.key] = name;
        }
      }
      await db.insert(_checkpoints, {'directory_uri': directory, 'stamp': '',
        'names_json': jsonEncode(names)}, conflictAlgorithm: ConflictAlgorithm.replace);
      return result;
    }
    await db.insert(_checkpoints, {'directory_uri': directory, 'stamp': stamp,
      'names_json': jsonEncode({for (final entry in previousNames.entries) if (expected.containsKey(entry.key)) entry.key: entry.value, for (final entry in entries.entries) if (expected.containsKey(entry.key)) entry.key: entry.value['name']})},
      conflictAlgorithm: ConflictAlgorithm.replace);
    return empty;
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
  StreamSubscription<void>? _librarySubscription;
  final _paths = <String>{};
  final _retries = <String, int>{};
  final _directories = <String, String?>{};
  final _directoryQueue = <String, bool>{};
  bool _reconcileRequested = false;
  Timer? _debounce, _watchDebounce;
  bool _working = false, _watching = false, _watchPending = false, _disposed = false;

  void start() {
    if (!Platform.isAndroid || _disposed || _subscription != null) return;
    _subscription = _events.receiveBroadcastStream().listen((dynamic event) {
      if (_disposed) return;
      if (event is String) {
        _retries.remove(event);
        _paths.add(event);
      } else if (event is Map && event['directory'] is String) {
        final directory = GridExternalIndex.locator(event['directory'] as String);
        if (directory == null || !_directories.containsKey(directory)) return;
        _directoryQueue[directory] = true;
      } else {
        return;
      }
      _scheduleDrain();
    }, onError: (Object _) {});
    _librarySubscription = PortableSnapshotEvents.gridWatchRefreshes.listen((_) => refreshWatches());
    refreshWatches(reconcile: true);
  }

  void refreshWatches({bool reconcile = false}) {
    if (!Platform.isAndroid || _disposed || _subscription == null) return;
    _watchPending = true;
    _reconcileRequested = _reconcileRequested || reconcile;
    _watchDebounce?.cancel();
    _watchDebounce = Timer(const Duration(milliseconds: 250), () => unawaited(_refresh()));
  }

  Future<void> _refresh() async {
    if (_disposed || _watching || !_watchPending) return;
    _watching = true;
    _watchPending = false;
    final reconcile = _reconcileRequested;
    _reconcileRequested = false;
    try {
      final db = await AppDatabase.instance.database;
      final rows = await db.query('folders', columns: ['id', 'storage_uri_or_relative_path'], where: 'deleted_at IS NULL');
      final directories = <String, String?>{};
      for (final row in rows) {
        final key = GridExternalIndex.locator(row['storage_uri_or_relative_path'] as String?);
        if (key != null) directories[key] = row['id'] as String;
      }
      if (_disposed) return;
      final result = await _channel.invokeMapMethod<String, dynamic>('setWatches', directories.keys.toList());
      final root = GridExternalIndex.locator(result?['unfiled'] as String?);
      if (root != null) directories.putIfAbsent(root, () => null);
      if (_disposed) return;
      for (final directory in directories.keys) {
        if (reconcile || !_directories.containsKey(directory)) {
          _directoryQueue.putIfAbsent(directory, () => false);
        }
      }
      _directories
        ..clear()
        ..addAll(directories);
      _directoryQueue.removeWhere((key, _) => !_directories.containsKey(key));
      if (_directoryQueue.isNotEmpty) _scheduleDrain();
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
    if (_disposed || _working || (_paths.isEmpty && _directoryQueue.isEmpty)) return;
    _working = true;
    final paths = _paths.take(48).toList();
    _paths.removeAll(paths);
    try {
      await StorageMigrationGate.waitUntilReady();
      final db = await AppDatabase.instance.database;
      final index = GridExternalIndex(db);
      final result = await index.applyPaths(paths,
        probe: (path) async => (await _channel.invokeMapMethod<String, Object?>('probe', path)) ?? const {'state': 'unknown'},
        digest: (path) => StorageLocationService.instance.sha256Pdf(Uri.file(path).toString()));
      for (final path in paths) { _retries.remove(path); }
      _publish(result);
      // Process at most one directory per batch, yielding between folders.
      // Precise local file events always take precedence.
      if (_directoryQueue.isNotEmpty && !_disposed) {
        final directory = _directoryQueue.keys.first;
        final force = _directoryQueue.remove(directory) ?? false;
        if (_directories.containsKey(directory)) {
          final reconciled = await index.reconcileDirectory(
            directory: directory, folderId: _directories[directory], force: force,
            snapshot: (uri, stamp) async => (await _channel.invokeMapMethod<String, Object?>(
              'snapshotDirectory', {'directory': uri, 'knownStamp': stamp})) ?? const {'complete': false},
            digest: (locator) => StorageLocationService.instance.sha256Pdf(
              GridExternalIndex.localPath(locator) != null ? Uri.file(locator).toString() : locator),
          );
          _publish(reconciled);
        }
      }
    } catch (_) {
      // Retry transient database failures at most twice, never scan storage.
      if (!_disposed) {
        for (final path in paths) {
          final attempts = (_retries[path] ?? 0) + 1;
          if (attempts <= 2) {
            _retries[path] = attempts;
            _paths.add(path);
          } else {
            _retries.remove(path);
          }
        }
      }
    } finally {
      _working = false;
      if ((_paths.isNotEmpty || _directoryQueue.isNotEmpty) && !_disposed) _scheduleDrain();
    }
  }

  void _publish(GridExternalResult result) {
    if (_disposed || result.affected.isEmpty) return;
    if (result.renamed) {
      PortableSnapshotEvents.notifyDataChanged(affectedFolderIds: result.affected, preciseGridFolders: true);
    } else {
      PortableSnapshotEvents.notifyGridAvailabilityChanged(result.affected);
    }
  }

  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _watchDebounce?.cancel();
    _subscription?.cancel();
    _librarySubscription?.cancel();
    _paths.clear();
    _retries.clear();
    _directoryQueue.clear();
    _directories.clear();
  }
}
