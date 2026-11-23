import 'dart:io';

import 'package:path/path.dart' as p;

/// Inspects only the two known DocsGrid-managed Android/media roots.
/// It never creates directories, changes the active root, or reads PDF bytes.
/// The result is a candidate, NOT a verification of snapshot/ZIP integrity.
class OldDocsGridSourceDiscovery {
  OldDocsGridSourceDiscovery._();

  static Future<Map<String, String>?> findIn(
    Iterable<Directory> possibleRoots,
  ) async {
    for (final root in possibleRoots) {
      final result = await inspect(root);
      if (result != null) return result;
    }
    return null;
  }

  static Future<Map<String, String>?> inspect(Directory root) async {
    if (!await root.exists()) return null;
    final canonical = Directory(p.join(root.path, 'My Files'));
    final system = Directory(p.join(root.path, 'System'));
    final newLayout = await canonical.exists() && await system.exists();
    final library = Directory(p.join(
        root.path, if (newLayout) 'My Files', 'Folders'));
    final documents = Directory(p.join(
        root.path, if (newLayout) 'My Files',
        if (newLayout) 'Unfiled' else 'Documents'));
    final database = Directory(p.join(
        root.path, if (newLayout) 'System', 'Database'));
    final recovery = Directory(p.join(
        root.path, if (newLayout) 'System', 'Recovery'));
    final backups = Directory(p.join(
        root.path, if (newLayout) 'System', 'Backups'));

    final hasMetadata = await _hasCompletedSnapshot(database);
    final hasArchive = await _hasArchivedBackup(backups);
    final hasPdfs = await _containsPdf(documents) || await _containsPdf(library);
    if (!hasMetadata && !hasArchive && !hasPdfs) return null;

    return <String, String>{
      'rootUri': root.uri.toString(),
      'databaseUri': database.uri.toString(),
      'recoveryUri': recovery.uri.toString(),
      'libraryUri': library.uri.toString(),
      'documentsUri': documents.uri.toString(),
      'backupsUri': backups.uri.toString(),
      'fullBackupsUri': Directory(p.join(backups.path, 'Full')).uri.toString(),
      'databaseBackupsUri':
          Directory(p.join(backups.path, 'Database')).uri.toString(),
      'detectedSnapshot': '$hasMetadata',
      'detectedBackup': '$hasArchive',
      'detectedPdfs': '$hasPdfs',
    };
  }

  static Future<bool> _hasCompletedSnapshot(Directory database) async {
    if (!await database.exists()) return false;
    try {
      await for (final entry in database.list(followLinks: false)) {
        if (entry is! Directory ||
            !p.basename(entry.path).startsWith('snapshot_')) continue;
        if (await File(p.join(entry.path, 'manifest.json')).isFile()) {
          return true;
        }
      }
    } on FileSystemException {
      return false;
    }
    return false;
  }

  static Future<bool> _hasArchivedBackup(Directory backupRoot) async {
    if (!await backupRoot.exists()) return false;
    final candidates = <Directory>[
      backupRoot,
      Directory(p.join(backupRoot.path, 'Full')),
      Directory(p.join(backupRoot.path, 'Database')),
    ];
    for (final folder in candidates) {
      if (!await folder.exists()) continue;
      try {
        await for (final entry in folder.list(followLinks: false)) {
          if (entry is File && p.extension(entry.path).toLowerCase() == '.zip') {
            return true;
          }
          if (entry is Directory &&
              RegExp(r'^A[0-9]{3,}$').hasMatch(p.basename(entry.path))) {
            if (await File(p.join(entry.path,
                '${p.basename(entry.path)}.zip')).exists()) return true;
          }
        }
      } on FileSystemException {
        continue;
      }
    }
    return false;
  }

  static Future<bool> _containsPdf(Directory directory) async {
    if (!await directory.exists()) return false;
    final pending = <({Directory dir, int depth})>[(dir: directory, depth: 0)];
    var scanned = 0;
    while (pending.isNotEmpty && scanned < 4000) {
      final current = pending.removeLast();
      try {
        await for (final entity in current.dir.list(followLinks: false)) {
          if (++scanned > 4000) return false; // A bounded discovery scan.
          if (entity is File &&
              p.extension(entity.path).toLowerCase() == '.pdf') return true;
          if (entity is Directory && current.depth < 12 &&
              !p.basename(entity.path).startsWith('.')) {
            pending.add((dir: entity, depth: current.depth + 1));
          }
        }
      } on FileSystemException {
        // A provider failure does not imply an empty tree.
      }
    }
    return false;
  }
}
