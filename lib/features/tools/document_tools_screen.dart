import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/database/app_database.dart';
import '../documents/data/document_repository.dart';
import 'document_tools_service.dart';
import '../../core/storage/storage_location_service.dart';

class DocumentToolsScreen extends StatefulWidget {
  const DocumentToolsScreen({super.key, this.quickAction, this.section = 'tools'});
  final String? quickAction;
  final String section;

  @override
  State<DocumentToolsScreen> createState() => _DocumentToolsScreenState();
}

class _DocumentToolsScreenState extends State<DocumentToolsScreen> {
  final _tools = DocumentToolsService();
  final _search = TextEditingController();
  List<Map<String, Object?>> _results = [];
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (widget.quickAction) {
        case 'camera': _scan(camera: true); break;
        case 'gallery': _scan(); break;
        case 'backup': _backup(); break;
        case 'tools': break;
      }
    });
  }

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
    final file = await _tools.scanToPdf(context: context, useCamera: camera);
    if (!mounted || file == null) return;

    final nameController = TextEditingController();
    final chosenName = await showDialog<String?>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Name your PDF'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'File name (optional)',
            hintText: 'Leave blank to use automatic name',
            suffixText: '.pdf',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, null), child: const Text('Skip')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, nameController.text.trim()), child: const Text('Continue')),
        ],
      ),
    );
    nameController.dispose();
    if (!mounted) return;

    final destination = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Where should this PDF be saved?')),
          ListTile(
            leading: const Icon(Icons.folder_special_outlined),
            title: const Text('DocsGrid library'),
            subtitle: const Text('Save in My Documents using the current library location.'),
            onTap: () => Navigator.pop(sheetContext, 'library'),
          ),
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text('Choose a storage folder'),
            subtitle: const Text('Select a folder in Internal storage or another available location.'),
            onTap: () => Navigator.pop(sheetContext, 'choose'),
          ),
        ]),
      ),
    );
    if (!mounted || destination == null) return;
    String? targetUri;
    if (destination == 'choose') {
      final folder = await StorageLocationService.instance.chooseFolder();
      if (folder == null) return;
      targetUri = folder['uri'];
    }

    final imported = await DocumentRepository().importScannedPdf(
      file,
      displayName: chosenName == null || chosenName.isEmpty ? null : chosenName,
      targetFolderUri: targetUri,
    );
    if (mounted) {
      setState(() => _message = imported.added == 1
        ? 'PDF saved in DocsGrid: ${chosenName == null || chosenName.isEmpty ? p.basename(file.path) : chosenName}.pdf'
        : 'This PDF already exists. Duplicate was not added.');
    }
  });

  Future<void> _backup() => _run(() async {
    final archive = await _tools.createBackup();
    if (!mounted) return;
    final directory = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose where to save DocsGrid backup',
    );
    if (directory == null || directory.isEmpty) {
      if (mounted) setState(() => _message = 'Backup was created temporarily. Choose a folder to save a permanent copy.');
      return;
    }
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final target = File(p.join(directory, 'DocsGrid_Backup_$stamp.zip'));
    await archive.copy(target.path);
    if (mounted) setState(() => _message = 'Offline backup saved successfully: ${target.path}');
  });

  Future<void> _createRecoverySnapshot() => _run(() async {
    final name = await _tools.createPortableMetadataSnapshot();
    if (mounted) {
      setState(() => _message = 'Recovery snapshot saved in DocsGrid/System/Database/$name. Tags, reminders, folders, settings and indexes are included.');
    }
  });

  Future<void> _verifyBackup() => _run(() async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    if (picked.isEmpty || picked.single.path == null) return;
    final count = await _tools.validateBackup(File(picked.single.path!));
    if (mounted) setState(() => _message = 'Backup integrity verified. $count PDF file(s) found.');
  });


  Future<void> _restoreBackup() => _run(() async {
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    if (picked.isEmpty || picked.single.path == null) return;
    final file = File(picked.single.path!);
    final count = await _tools.validateBackup(file);
    if (!mounted) return;
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Restore backup?'),
      content: Text('The archive contains $count PDF file(s). DocsGrid will add the restored folders and documents without overwriting existing records. ID conflicts stop the restore.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Restore')),
      ],
    ));
    if (confirmed != true) return;
    final restored = await _tools.restoreBackup(file);
    if (mounted) setState(() => _message = 'Restore completed: $restored PDF file(s) restored and verified.');
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
      if (uri == null || uri.isEmpty) {
        skipped++;
        continue;
      }
      try {
        await _tools.indexPdfTextFromUri(row['id'] as String, uri);
        done++;
      } catch (_) {
        skipped++;
      }
    }
    if (mounted) setState(() => _message = 'OCR indexing finished: $done indexed, $skipped skipped or failed. Provider PDFs are copied to temporary local storage for OCR.');
  });


  Future<void> _reviewDuplicateGroup(String sha) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('documents',
      where: 'sha256 = ? AND deleted_at IS NULL', whereArgs: [sha],
      orderBy: 'created_at ASC');
    final docs = rows.map(DocumentRecord.fromMap).toList();
    if (docs.length < 2 || !mounted) return;
    String keepId = docs.first.id;
    final remove = await showDialog<bool>(context: context, builder: (dialogContext) => StatefulBuilder(
      builder: (context, refresh) => AlertDialog(
        title: const Text('Review duplicate PDFs'),
        content: SizedBox(width: 440, child: ListView(shrinkWrap: true, children: [
          const Text('Choose the copy to keep. All other copies will be moved to Recycle Bin, not permanently deleted.'),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: keepId,
            onChanged: (value) { if (value != null) refresh(() => keepId = value); },
            child: Column(children: [
              for (final doc in docs)
                RadioListTile<String>(
                  value: doc.id,
                  title: Text('${doc.name}.pdf'),
                  subtitle: Text('${doc.sizeBytes} bytes · ${doc.storagePath}'),
                ),
            ]),
          ),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Keep selected copy')),
        ],
      ),
    ));
    if (remove != true) return;
    for (final doc in docs) {
      if (doc.id != keepId) await DocumentRepository().moveToTrash(doc);
    }
    if (mounted) {
      setState(() => _message = 'Duplicate review complete. Kept 1 copy and moved ${docs.length - 1} copy/copies to Recycle Bin.');
    }
  }

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
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.pop(context);
              _reviewDuplicateGroup(g['sha256'] as String);
            },
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
      if (widget.section == 'tools') ...[
        Card(child: Column(children: [
          ListTile(leading: const Icon(Icons.text_snippet_outlined),
            title: const Text('On-device OCR indexing'),
            trailing: IconButton(tooltip: 'Start indexing', onPressed: _busy ? null : _indexDocuments,
              icon: const Icon(Icons.play_arrow))),
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: Column(children: [
            TextField(controller: _search, decoration: InputDecoration(
              labelText: 'Search text inside indexed PDFs',
              suffixIcon: IconButton(onPressed: _searchText, icon: const Icon(Icons.search))),
              onSubmitted: (_) => _searchText()),
            if (_results.isNotEmpty) ...[
              const SizedBox(height: 8),
              ..._results.map((r) => ListTile(dense: true,
                title: Text((r['name'] ?? '').toString()),
                subtitle: Text('Text match at character ${r['match_position']}'))),
            ],
          ])),
          const Divider(height: 1),
          ListTile(leading: const Icon(Icons.copy_all_outlined),
            title: const Text('Duplicate review'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _showDuplicates),
        ])),
      ],
      if (widget.section == 'backup') Card(child: Column(children: [
        ListTile(leading: const Icon(Icons.folder_copy_outlined),
          title: const Text('Save recovery snapshot to DocsGrid folder'),
          subtitle: const Text('Saves tags, reminders, folders, settings and metadata beside your library.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : _createRecoverySnapshot),
        const Divider(height: 1),
        ListTile(leading: const Icon(Icons.backup_outlined),
          title: const Text('Create offline backup'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : _backup),
      ])),
      if (widget.section == 'restore') Card(child: Column(children: [
        ListTile(leading: const Icon(Icons.settings_backup_restore_outlined),
          title: const Text('Restore backup'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : _restoreBackup),
        const Divider(height: 1),
        ListTile(leading: const Icon(Icons.verified_outlined),
          title: const Text('Verify backup ZIP'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : _verifyBackup),
      ])),
    ],
  );
}
