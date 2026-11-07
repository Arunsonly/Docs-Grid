import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/database/app_database.dart';
import 'document_tools_service.dart';

class DocumentToolsScreen extends StatefulWidget {
  const DocumentToolsScreen({super.key});

  @override
  State<DocumentToolsScreen> createState() => _DocumentToolsScreenState();
}

class _DocumentToolsScreenState extends State<DocumentToolsScreen> {
  final _tools = DocumentToolsService();
  final _search = TextEditingController();
  List<Map<String, Object?>> _results = [];
  bool _busy = false;
  String? _message;

  Future<void> _run(Future<void> Function() action) async {
    setState(() { _busy = true; _message = null; });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _message = 'Action could not be completed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan({bool camera = false}) => _run(() async {
    final file = await _tools.scanToPdf(useCamera: camera);
    if (file == null) return;
    await _tools.shareFile(file.path, text: 'Scanned with DocsGrid');
    if (mounted) setState(() => _message = 'Scan PDF created: ${p.basename(file.path)}');
  });

  Future<void> _backup() => _run(() async {
    final file = await _tools.createBackup();
    await _tools.shareFile(file.path, text: 'DocsGrid offline backup');
    if (mounted) setState(() => _message = 'Backup created and opened in the share sheet.');
  });

  Future<void> _verifyBackup() => _run(() async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    if (picked.isEmpty || picked.single.path == null) return;
    final count = await _tools.validateBackup(File(picked.single.path!));
    if (mounted) setState(() => _message = 'Backup integrity verified. $count PDF file(s) found. Restore is not enabled yet.');
  });

  Future<void> _searchText() async {
    final rows = await _tools.searchText(_search.text);
    if (mounted) setState(() => _results = rows);
  }

  Future<void> _indexDocuments() => _run(() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('documents', columns: ['id', 'name', 'storage_uri'],
      where: 'deleted_at IS NULL');
    var done = 0;
    var skipped = 0;
    for (final row in rows) {
      final uri = row['storage_uri'] as String?;
      if (uri == null || uri.isEmpty || uri.startsWith('content://') || uri.startsWith('file://')) {
        skipped++;
        continue;
      }
      try {
        await _tools.indexPdfText(row['id'] as String, uri);
        done++;
      } catch (_) {
        skipped++;
      }
    }
    if (mounted) setState(() => _message = 'OCR indexing finished: $done indexed, $skipped skipped or failed. Cloud/provider PDFs need local device access.');
  });

  Future<void> _showDuplicates() async {
    final groups = await _tools.findExactDuplicates();
    if (!mounted) return;
    await showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: const Text('Exact duplicate PDFs'),
      content: SizedBox(width: 420, child: groups.isEmpty
        ? const Text('No exact SHA-256 duplicates found.')
        : ListView(shrinkWrap: true, children: groups.map((g) => ListTile(
            title: Text('${g['copies']} identical copies'),
            subtitle: Text((g['names'] ?? '').toString()),
          )).toList())),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    ));
  }

  @override
  void dispose() { _search.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      if (_busy) const LinearProgressIndicator(),
      if (_message != null) Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(_message!, style: Theme.of(context).textTheme.bodyMedium),
      ),
      Card(child: Column(children: [
        ListTile(leading: const Icon(Icons.document_scanner_outlined),
          title: const Text('Scan using camera'),
          subtitle: const Text('Capture a page and create a PDF.'),
          onTap: _busy ? null : () => _scan(camera: true)),
        const Divider(height: 1),
        ListTile(leading: const Icon(Icons.photo_library_outlined),
          title: const Text('Create PDF from gallery images'),
          subtitle: const Text('Select multiple images and combine them into one PDF.'),
          onTap: _busy ? null : _scan),
        const Divider(height: 1),
        ListTile(leading: const Icon(Icons.share_outlined),
          title: const Text('Quick share'),
          subtitle: const Text('Share a PDF from the Files list using its document menu.')),
      ])),
      Card(child: Column(children: [
        ListTile(leading: const Icon(Icons.text_snippet_outlined),
          title: const Text('On-device OCR indexing'),
          subtitle: const Text('Recognise text from PDF page images on this device. No cloud OCR.'),
          trailing: IconButton(tooltip: 'Start indexing', onPressed: _busy ? null : _indexDocuments,
            icon: const Icon(Icons.play_arrow))),
        Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: Column(children: [
          TextField(controller: _search, decoration: InputDecoration(
            labelText: 'Search text inside indexed PDFs',
            suffixIcon: IconButton(onPressed: _searchText, icon: const Icon(Icons.search))),
            onSubmitted: (_) => _searchText()),
          if (_results.isNotEmpty) ...[
            const SizedBox(height: 8),
            ..._results.map((r) => ListTile(
              dense: true, title: Text((r['name'] ?? '').toString()),
              subtitle: Text('Text match at character ${r['match_position']}'),
            )),
          ],
        ])),
      ])),
      Card(child: Column(children: [
        ListTile(leading: const Icon(Icons.copy_all_outlined),
          title: const Text('Duplicate review'),
          subtitle: const Text('Find exact matches by SHA-256. Nothing is deleted automatically.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : _showDuplicates),
        const Divider(height: 1),
        ListTile(leading: const Icon(Icons.backup_outlined),
          title: const Text('Create offline backup'),
          subtitle: const Text('Build a ZIP archive with database metadata and locally accessible PDFs.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : _backup),
        const Divider(height: 1),
        ListTile(leading: const Icon(Icons.verified_outlined),
          title: const Text('Verify backup ZIP'),
          subtitle: const Text('Check manifest, PDF entries and SHA-256 integrity before restore.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : _verifyBackup),
      ])),
    ],
  );
}
