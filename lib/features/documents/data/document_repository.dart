import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';

class DocumentRecord {
  const DocumentRecord({
    required this.id,
    required this.name,
    required this.storagePath,
    required this.sizeBytes,
    required this.createdAt,
    required this.isFavorite,
  });

  final String id;
  final String name;
  final String storagePath;
  final int sizeBytes;
  final DateTime createdAt;
  final bool isFavorite;

  factory DocumentRecord.fromMap(Map<String, Object?> row) {
    final metadata = jsonDecode((row['metadata_json'] as String?) ?? '{}')
        as Map<String, dynamic>;
    return DocumentRecord(
      id: row['id'] as String,
      name: row['name'] as String,
      storagePath: (row['storage_uri'] as String?) ?? '',
      sizeBytes: (row['size_bytes'] as int?) ?? 0,
      createdAt: DateTime.parse(row['created_at'] as String),
      isFavorite: metadata['favorite'] == true,
    );
  }
}

class ImportSummary {
  const ImportSummary({required this.added, required this.duplicates, required this.failed});
  final int added;
  final int duplicates;
  final int failed;
}

class DocumentRepository {
  DocumentRepository({AppDatabase? database})
      : _database = database ?? AppDatabase.instance;

  final AppDatabase _database;
  static const _uuid = Uuid();

  Future<List<DocumentRecord>> list({String query = '', bool favoritesOnly = false}) async {
    final db = await _database.database;
    final rows = await db.query(
      'documents',
      where: "deleted_at IS NULL AND (? = 0 OR COALESCE(json_extract(metadata_json, '\$.favorite'), 0) = 1) AND name LIKE ?",
      whereArgs: [favoritesOnly ? 1 : 0, '%${query.trim()}%'],
      orderBy: 'last_opened_at DESC, name COLLATE NOCASE ASC',
    );
    return rows.map(DocumentRecord.fromMap).toList();
  }

  Future<ImportSummary> importPdfs() async {
    final pickedFiles = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (pickedFiles.isEmpty) {
      return const ImportSummary(added: 0, duplicates: 0, failed: 0);
    }

    final base = await getApplicationDocumentsDirectory();
    final library = Directory(p.join(base.path, 'DocsGrid', 'PDFs'));
    await library.create(recursive: true);
    final db = await _database.database;
    var added = 0;
    var duplicates = 0;
    var failed = 0;

    for (final picked in pickedFiles) {
      try {
        final bytes = await picked.readAsBytes();
        if (bytes.isEmpty) {
          failed++;
          continue;
        }
        final digest = sha256.convert(bytes).toString();
        final existing = await db.query(
          'documents',
          columns: ['id'],
          where: 'sha256 = ? AND deleted_at IS NULL',
          whereArgs: [digest],
          limit: 1,
        );
        if (existing.isNotEmpty) {
          duplicates++;
          continue;
        }
        final safeName = _safePdfName(picked.name);
        final target = await _uniqueFile(library, safeName);
        await target.writeAsBytes(bytes, flush: true);
        final now = DateTime.now().toUtc().toIso8601String();
        await db.insert('documents', {
          'id': _uuid.v4(),
          'name': p.basenameWithoutExtension(target.path),
          'original_name': picked.name,
          'storage_uri': target.path,
          'relative_path': p.relative(target.path, from: library.path),
          'mime_type': 'application/pdf',
          'size_bytes': bytes.length,
          'sha256': digest,
          'extracted_text_status': 'pending',
          'created_at': now,
          'updated_at': now,
          'metadata_json': '{}',
          'source': 'file_picker',
        });
        added++;
      } catch (_) {
        failed++;
      }
    }
    return ImportSummary(added: added, duplicates: duplicates, failed: failed);
  }

  String _safePdfName(String name) {
    var cleaned = p.basename(name).replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
    if (cleaned.isEmpty) cleaned = 'Document.pdf';
    if (!cleaned.toLowerCase().endsWith('.pdf')) cleaned = '$cleaned.pdf';
    return cleaned;
  }

  Future<File> _uniqueFile(Directory directory, String name) async {
    var candidate = File(p.join(directory.path, name));
    var counter = 1;
    while (await candidate.exists()) {
      final stem = p.basenameWithoutExtension(name);
      candidate = File(p.join(directory.path, '$stem ($counter).pdf'));
      counter++;
    }
    return candidate;
  }

  Future<void> setFavorite(DocumentRecord document, bool favorite) async {
    final db = await _database.database;
    await db.update(
      'documents',
      {'metadata_json': jsonEncode({'favorite': favorite}), 'updated_at': DateTime.now().toUtc().toIso8601String()},
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [document.id],
    );
  }

  Future<void> markOpened(DocumentRecord document) async {
    final db = await _database.database;
    await db.update('documents', {
      'last_opened_at': DateTime.now().toUtc().toIso8601String(),
    }, where: 'id = ?', whereArgs: [document.id]);
  }

  Future<void> moveToTrash(DocumentRecord document) async {
    final db = await _database.database;
    await db.update('documents', {
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, where: 'id = ?', whereArgs: [document.id]);
  }

  Future<void> rename(DocumentRecord document, String newName) async {
    final cleaned = newName.trim();
    if (cleaned.isEmpty) throw ArgumentError('Name cannot be empty.');
    final oldFile = File(document.storagePath);
    final extension = p.extension(oldFile.path).isEmpty ? '.pdf' : p.extension(oldFile.path);
    final safeBase = p.basenameWithoutExtension(cleaned).replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final newFile = File(p.join(oldFile.parent.path, '$safeBase$extension'));
    if (await newFile.exists() && newFile.path != oldFile.path) {
      throw StateError('A file with this name already exists.');
    }
    if (await oldFile.exists()) await oldFile.rename(newFile.path);
    final db = await _database.database;
    await db.update('documents', {
      'name': p.basenameWithoutExtension(newFile.path),
      'storage_uri': newFile.path,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, where: 'id = ?', whereArgs: [document.id]);
  }

  Future<void> permanentlyDelete(DocumentRecord document) async {
    final file = File(document.storagePath);
    if (await file.exists()) await file.delete();
    final db = await _database.database;
    await db.delete('documents', where: 'id = ?', whereArgs: [document.id]);
  }
}
