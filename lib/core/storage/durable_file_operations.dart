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
  FileOperationLease._(this.db, this.resourceKey, this.id, this.ownerId, this.previousPhase);

  final Database db;
  final String resourceKey;
  final String id;
  final String ownerId;
  /// Phase recorded by a previous process before this operation was resumed.
  /// A missing folder is only expected when deletion reached directory cleanup.
  final String? previousPhase;

  bool get mayHaveDeletedDirectories =>
      previousPhase == 'deleting-empty-directories' ||
      previousPhase == 'deleting-folder-records';

  /// Record the successful SQLite commit marker in the SAME transaction
  /// that changes PDF metadata. Crash-after-commit/before-Finalize can then
  /// be reconciled without redoing physical file operations.
  Future<void> markDatabaseCommitted(DatabaseExecutor txn) async {
    final updated = await txn.update('file_operation_journal', {
      'phase': 'db-committed',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, where: "resource_key = ? AND operation_id = ? AND owner_id = ? "
          "AND state = 'running'",
        whereArgs: [resourceKey, id, ownerId]);
    if (updated != 1) {
      throw StateError('PDF operation lost ownership before database commit.');
    }
  }

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
  /// All affected resources are leased atomically in SQLite, and their OS
  /// advisory locks are acquired in sorted order. A crashed operation leaves
  /// incomplete scope reservations behind, so an unrelated operation cannot
  /// reclaim a child PDF before the interrupted parent operation is resolved.
  ///
  /// The primary key owns the journal and its crash phase. Extra keys are
  /// durable reservations only; no new database schema is required.
  static Future<T> run<T>({
    required Database db,
    required String resourceKey,
    required String kind,
    Iterable<String> scopeKeys = const <String>[],
    required Future<T> Function(FileOperationLease lease) action,
  }) async {
    if (resourceKey.isEmpty || kind.isEmpty) {
      throw ArgumentError('PDF operation must identify its resource and kind.');
    }
    final keys = <String>{resourceKey, ...scopeKeys};
    if (keys.any((key) => key.isEmpty)) {
      throw ArgumentError('Scope keys must not be empty.');
    }
    final orderedKeys = keys.toList()..sort();
    if (orderedKeys.any(_activeResources.contains)) {
      throw StateError('A conflicting folder or PDF operation is already active.');
    }
    _activeResources.addAll(orderedKeys);
    final locks = <RandomAccessFile>[];
    try {
      // Acquire OS locks in deterministic order across isolates/processes.
      for (final key in orderedKeys) {
        final handle = await (await _operationLockFile(db, key))
            .open(mode: FileMode.append);
        locks.add(handle);
        await handle.lock(FileLock.exclusive);
      }
      String? previousPhase;
      final operationId = await db.transaction<String>((txn) async {
        final primary = await txn.query(
          'file_operation_journal',
          where: 'resource_key = ?', whereArgs: [resourceKey], limit: 1,
        );
        final now = DateTime.now().toUtc().toIso8601String();
        final previous = primary.isEmpty ? null : primary.single;
        final oldState = previous?['state'] as String?;
        if (oldState != null && oldState != 'completed' &&
            previous?['kind'] != kind) {
          throw StateError(
            'An interrupted ${previous?['kind']} operation must be recovered '
            'before $kind.',
          );
        }
        if (oldState != null && oldState != 'completed' &&
            previous?['phase'] == 'db-committed') {
          throw StateError('Previous file operation already committed. '
              'Reconcile it before starting another action.');
        }
        previousPhase = oldState != null && oldState != 'completed'
            ? previous?['phase'] as String? : null;
        final id = previous != null && oldState != 'completed'
            ? previous['operation_id'] as String : _uuid.v4();

        // Check all reservations BEFORE updating any journal record. This
        // catches a crashed folder delete even if the physical OS lock has
        // since been released. Reads and searches remain unaffected.
        for (final key in orderedKeys) {
          final rows = await txn.query(
            'file_operation_journal',
            columns: ['operation_id', 'kind', 'state', 'phase'],
            where: 'resource_key = ?', whereArgs: [key], limit: 1,
          );
          if (rows.isEmpty) continue;
          final row = rows.single;
          if (row['state'] != 'completed' && row['operation_id'] != id) {
            throw StateError('An interrupted folder or PDF operation owns $key.');
          }
          if (row['state'] != 'completed' && key != resourceKey &&
              row['kind'] != 'scope') {
            throw StateError('Another incomplete PDF operation owns $key.');
          }
        }
        for (final key in orderedKeys) {
          final isPrimary = key == resourceKey;
          final data = <String, Object?>{
            'operation_id': id,
            'kind': isPrimary ? kind : 'scope',
            'owner_id': _processOwner,
            'state': 'running',
            'phase': isPrimary ? 'preflight' : 'scope-held',
            'updated_at': now,
          };
          final existing = await txn.query('file_operation_journal',
              columns: ['resource_key'],
              where: 'resource_key = ?', whereArgs: [key], limit: 1);
          if (existing.isEmpty) {
            await txn.insert('file_operation_journal', {
              'resource_key': key, ...data, 'created_at': now,
            });
          } else {
            await txn.update('file_operation_journal', data,
                where: 'resource_key = ?', whereArgs: [key]);
          }
        }
        return id;
      });
      final lease = FileOperationLease._(
        db, resourceKey, operationId, _processOwner, previousPhase,
      );
      try {
        final value = await action(lease);
        await db.transaction((txn) async {
          final updated = await txn.update('file_operation_journal', {
            'state': 'completed', 'phase': 'completed',
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }, where: "operation_id = ? AND owner_id = ? AND state = 'running'",
              whereArgs: [operationId, _processOwner]);
          if (updated == 0) throw StateError('File operation lost its journal.');
        });
        return value;
      } catch (_) {
        try {
          await db.transaction((txn) async {
            final current = await txn.query(
              'file_operation_journal', columns: ['phase'],
              where: 'resource_key = ? AND operation_id = ? AND owner_id = ?',
              whereArgs: [resourceKey, operationId, _processOwner], limit: 1,
            );
            final phase = current.isEmpty ? null : current.single['phase'];
            final noPhysicalChanges =
                phase == 'provider-rename-rolled-back' ||
                (phase == 'preflight' &&
                    (previousPhase == null || previousPhase == 'preflight'));
            if (noPhysicalChanges) {
              await txn.update('file_operation_journal', {
                'state': 'completed',
                'phase': 'rejected-before-write',
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              }, where: "operation_id = ? AND owner_id = ? AND state = 'running'",
                  whereArgs: [operationId, _processOwner]);
            } else {
              // Preserve the PRIMARY crash phase. Scope rows retain the
              // operation id and remain reserved across restarts.
              await txn.update('file_operation_journal', {
                'state': 'interrupted',
                'updated_at': DateTime.now().toUtc().toIso8601String(),
              }, where: "operation_id = ? AND owner_id = ? AND state = 'running'",
                  whereArgs: [operationId, _processOwner]);
            }
          });
        } catch (_) {
          // Do not replace the original physical operation error.
        }
        rethrow;
      }
    } finally {
      for (final handle in locks.reversed) {
        try { await handle.unlock(); } catch (_) {}
        try { await handle.close(); } catch (_) {}
      }
      _activeResources.removeAll(orderedKeys);
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
      // This marker is written in the same SQLite transaction as the
      // metadata operation or after its successfully returned callback.
      // Therefore it proves the DB commit without relying on file existence.
      bool committed = phase == 'db-committed';
      if (!committed && kind == 'delete-folder-tree' &&
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
      } else if (!committed && kind == 'delete-pdf' &&
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
        try { await recoveryLock.unlock(); } catch (_) {}
        try { await recoveryLock.close(); } catch (_) {}
      }
    }
    // The owner committed all metadata but died before releasing scoped
    // reservations. Their completed primary operation proves they are safe
    // to release, including keys no longer visible in a partially deleted tree.
    completed += await db.rawUpdate('''
      UPDATE file_operation_journal SET
        state = 'completed', phase = 'reconciled-scope',
        updated_at = ?
      WHERE kind = 'scope' AND state != 'completed'
        AND EXISTS (
          SELECT 1 FROM file_operation_journal parent
          WHERE parent.operation_id = file_operation_journal.operation_id
            AND parent.kind != 'scope' AND parent.state = 'completed'
        )
    ''', [DateTime.now().toUtc().toIso8601String()]);
    return completed;
  }

  static Future<List<Map<String, Object?>>> incomplete(Database db) =>
      db.query('file_operation_journal',
          where: "state != 'completed'", orderBy: 'updated_at ASC');
}
