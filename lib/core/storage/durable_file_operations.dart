import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

/// Durable, per-resource ownership. Do not lock unrelated PDF reads/search.
/// Ownership and phase survive process death; incomplete operations can only
/// be retried by the same operation kind after a fresh storage preflight.
class FileOperationLease {
  FileOperationLease._(this.db, this.resourceKey, this.id, this.ownerId);

  final Database db;
  final String resourceKey;
  final String id;
  final String ownerId;

  Future<void> phase(String phase) async {
    final count = await db.update('file_operation_journal', {
      'phase': phase,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, where: "resource_key = ? AND operation_id = ? AND owner_id = ? AND state = 'running'",
        whereArgs: [resourceKey, id, ownerId]);
    if (count != 1) throw StateError('PDF operation ownership was lost.');
  }
}

class DurableFileOperations {
  DurableFileOperations._();

  static const _uuid = Uuid();
  static final String _processOwner = _uuid.v4();
  static final Set<String> _activeResources = <String>{};

  /// Independent operations get independent keys; folder delete and restore
  /// share a trash-operation key so child/parent changes cannot interleave.
  static Future<T> run<T>({
    required Database db,
    required String resourceKey,
    required String kind,
    required Future<T> Function(FileOperationLease lease) action,
  }) async {
    if (resourceKey.isEmpty || kind.isEmpty) {
      throw ArgumentError('PDF operation must identify its resource and kind.');
    }
    // SQLite ownership prevents conflicts in the database. An OS advisory
    // lock additionally prevents a second process/isolate from reclaiming a
    // running owner while that worker is still deleting physical bytes.
    if (!_activeResources.add(resourceKey)) {
      throw StateError('A PDF operation is already running for this resource.');
    }
    RandomAccessFile? processLock;
    try {
      final lockFile = await _operationLockFile(db, resourceKey);
      processLock = await lockFile.open(mode: FileMode.append);
      await processLock.lock(FileLock.exclusive);
    final operationId = await db.transaction<String>((txn) async {
      final rows = await txn.query(
        'file_operation_journal',
        where: 'resource_key = ?', whereArgs: [resourceKey], limit: 1,
      );
      final now = DateTime.now().toUtc().toIso8601String();
      if (rows.isNotEmpty) {
        final old = rows.single;
        final state = old['state'] as String;
        final previousKind = old['kind'] as String;
        if (state == 'running' && old['owner_id'] == _processOwner) {
          throw StateError('A PDF operation is already running for this folder or file.');
        }
        if (state != 'completed' && previousKind != kind) {
          throw StateError(
            'An interrupted $previousKind operation must be recovered before $kind.',
          );
        }
        // A previous process can no longer manipulate files. On restart the
        // same operation is retried after its caller revalidates the sources.
        final id = state == 'completed' ? _uuid.v4() :
            old['operation_id'] as String;
        await txn.update('file_operation_journal', {
          'operation_id': id, 'kind': kind, 'owner_id': _processOwner,
          'state': 'running', 'phase': 'preflight', 'updated_at': now,
          if (state == 'completed') 'created_at': now,
        }, where: 'resource_key = ?', whereArgs: [resourceKey]);
        return id;
      }
      final id = _uuid.v4();
      await txn.insert('file_operation_journal', {
        'resource_key': resourceKey, 'operation_id': id, 'kind': kind,
        'owner_id': _processOwner, 'state': 'running',
        'phase': 'preflight', 'created_at': now, 'updated_at': now,
      });
      return id;
    });
    final lease = FileOperationLease._(db, resourceKey, operationId, _processOwner);
    try {
      final value = await action(lease);
      await lease.phase('db-committed');
      await db.update('file_operation_journal', {
        'state': 'completed',
        'phase': 'completed',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, where: 'resource_key = ? AND operation_id = ? AND owner_id = ? AND state = ?',
          whereArgs: [resourceKey, operationId, _processOwner, 'running']);
      return value;
    } catch (_) {
      try {
        final current = await db.query(
          'file_operation_journal', columns: ['phase'],
          where: 'resource_key = ? AND operation_id = ? AND owner_id = ?',
          whereArgs: [resourceKey, operationId, _processOwner], limit: 1,
        );
        // A rejected preflight did not mutate any PDF bytes or database row.
        // Never let a harmless invalid individual-restore attempt permanently
        // prevent recovery of its parent folder.
        final noPhysicalChanges = current.isNotEmpty &&
            current.single['phase'] == 'preflight';
        await db.update('file_operation_journal', {
          'state': noPhysicalChanges ? 'completed' : 'interrupted',
          'phase': noPhysicalChanges ? 'rejected-before-write'
              : (current.isNotEmpty ? current.single['phase'] : 'unknown'),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }, where: 'resource_key = ? AND operation_id = ? AND owner_id = ? AND state = ?',
            whereArgs: [resourceKey, operationId, _processOwner, 'running']);
      } catch (_) {
        // Never replace the original error with a journal-write failure.
      }
      rethrow;
    }
    } finally {
      try { await processLock?.unlock(); } catch (_) {}
      try { await processLock?.close(); } catch (_) {}
      _activeResources.remove(resourceKey);
    }
  }

  /// Reconcile only operations whose final SQLite state proves that their
  /// terminal database commit succeeded. Never infer physical deletion from
  /// a missing file, and never automatically retry an irreversible delete.
  /// All other interrupted operations remain visible for safe same-kind retry.
  static Future<File> _operationLockFile(
      Database db, String resourceKey) async {
    final root = p.isAbsolute(db.path) ? p.dirname(db.path)
        : Directory.systemTemp.path;
    final directory = Directory(p.join(root, 'docsgrid_file_operation_locks'));
    await directory.create(recursive: true);
    final token = sha256.convert(utf8.encode(resourceKey)).toString();
    return File(p.join(directory.path, '$token.lock'));
  }

  static Future<int> reconcileFinished(Database db) async {
    final rows = await db.query(
      'file_operation_journal',
      where: "state != 'completed'",
    );
    var completed = 0;
    for (final row in rows) {
      final key = row['resource_key'] as String;
      // A different process may still be deleting bytes while this instance
      // opens SQLite. Never reconcile and release that process's ownership
      // until the same physical OS lock is available without blocking.
      RandomAccessFile? recoveryLock;
      try {
        recoveryLock = await (await _operationLockFile(db, key))
            .open(mode: FileMode.append);
        await recoveryLock.lock(FileLock.exclusive);
      } on FileSystemException {
        try { await recoveryLock?.close(); } catch (_) {}
        continue;
      }
      try {
      final kind = row['kind'] as String;
      final phase = row['phase'] as String;
      bool committed = false;
      if (kind == 'delete-folder-tree' &&
          key.startsWith('trash-tree:') &&
          phase == 'deleting-folder-records') {
        final operationId = key.substring('trash-tree:'.length);
        final folderCount = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM folders WHERE trash_operation_id = ?',
          [operationId],
        )) ?? 0;
        final documentCount = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM documents WHERE trash_operation_id = ?',
          [operationId],
        )) ?? 0;
        committed = folderCount == 0 && documentCount == 0;
      } else if (kind == 'delete-pdf' &&
          key.startsWith('document:') &&
          phase == 'deleting-pdf-record') {
        final documentId = key.substring('document:'.length);
        final existing = await db.query('documents',
          columns: ['id'], where: 'id = ?', whereArgs: [documentId],
          limit: 1,
        );
        committed = existing.isEmpty;
      }
      if (!committed) continue;
      final n = await db.update('file_operation_journal', {
        'state': 'completed',
        'phase': 'reconciled-after-restart',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, where: "resource_key = ? AND operation_id = ? AND state != 'completed'",
          whereArgs: [key, row['operation_id']]);
      completed += n;
      } finally {
        try { await recoveryLock?.unlock(); } catch (_) {}
        try { await recoveryLock?.close(); } catch (_) {}
      }
    }
    return completed;
  }

  static Future<List<Map<String, Object?>>> incomplete(Database db) =>
      db.query('file_operation_journal',
          where: "state != 'completed'", orderBy: 'updated_at ASC');
}
