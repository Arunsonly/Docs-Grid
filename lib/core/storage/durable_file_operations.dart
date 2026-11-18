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
        await db.update('file_operation_journal', {
          'state': 'interrupted',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }, where: 'resource_key = ? AND operation_id = ? AND owner_id = ? AND state = ?',
            whereArgs: [resourceKey, operationId, _processOwner, 'running']);
      } catch (_) {
        // Never replace the original error with a journal-write failure.
      }
      rethrow;
    }
  }

  static Future<List<Map<String, Object?>>> incomplete(Database db) =>
      db.query('file_operation_journal',
          where: "state != 'completed'", orderBy: 'updated_at ASC');
}
