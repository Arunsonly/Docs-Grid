import 'dart:convert';

import 'package:sqflite/sqflite.dart';

/// Recognizes only the exact committed staging job, never matching PDF bytes.
class ShareImportReceipts {
  ShareImportReceipts._();

  static Future<bool> isCommitted(
    DatabaseExecutor db, {
    required String id, required String sha256,
  }) async {
    if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id)) {
      throw ArgumentError('Invalid share import job ID.');
    }
    // The LIKE search only narrows candidates; verify parsed JSON exactly.
    // SQLite JSON1 is not guaranteed on every supported Android version.
    final rows = await db.query(
      'documents', columns: ['sha256', 'metadata_json'],
      where: "source = 'share' AND metadata_json LIKE ?",
      whereArgs: ['%"shareImportId":"$id"%'],
    );
    for (final row in rows) {
      final raw = row['metadata_json'];
      if (raw is! String) continue;
      try {
        final metadata = jsonDecode(raw);
        if (metadata is! Map || metadata['shareImportId'] != id) continue;
      } on FormatException {
        continue;
      }
      if ((row['sha256'] as String?)?.toLowerCase() != sha256.toLowerCase()) {
        throw StateError('Staged PDF bytes changed after its import was committed.');
      }
      return true;
    }
    return false;
  }
}
