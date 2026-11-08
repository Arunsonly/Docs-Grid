import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import '../../core/database/app_database.dart';
import '../documents/data/document_repository.dart';
import '../folders/data/folder_repository.dart';
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

    final folders = await FolderRepository().allFoldersWithPaths();
    if (!mounted) return;
    final destination = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Choose DocsGrid folder')),
          ListTile(
            leading: const Icon(Icons.home_outlined),
            title: const Text('My Documents (root)'),
            onTap: () => Navigator.pop(sheetContext, ''),
          ),
          for (final option in folders)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(option.path),
              onTap: () => Navigator.pop(sheetContext, option.folder.id),
            ),
        ]),
      ),
    );
    if (!mounted || destination == null) return;

    final imported = await DocumentRepository().importScannedPdf(
      file,
      displayName: chosenName == null || chosenName.isEmpty ? null : chosenName,
      targetFolderId: destination.isEmpty ? null : destination,
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

  Future<void> _verifyRecoverySnapshot() => _run(() async {
    final name = await _tools.verifyLatestPortableMetadataSnapshot();
    if (!mounted) return;
    setState(() => _message = name == null
      ? 'No portable recovery snapshot found. Create one first.'
      : 'Recovery snapshot verified successfully: $name');
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

  Future<void> _restorePortableSnapshot() => _run(() async {
    final selected = await StorageLocationService.instance.chooseFolder();
    if (selected == null) return;
    final snapshot = await _tools.verifyLatestPortableMetadataSnapshot();
    if (snapshot == null) {
      throw StateError('No verified DocsGrid snapshot was found in the selected folder.');
    }
    if (!mounted) return;
    final androidNote = Platform.isAndroid
        ? 'Choose the parent folder that contains the existing DocsGrid folder.'
        : 'Choose the existing DocsGrid data folder that contains System/Database.';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restore DocsGrid folder data?'),
        content: Text(
          'Verified snapshot: $snapshot\n\n$androidNote\n'
          'Existing records will be retained. Imported IDs will be remapped if needed. '
          'PDFs will be matched by SHA-256; files not found will keep their metadata '
          'and be marked for relinking. No PDF file will be overwritten or deleted.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Restore')),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = await _tools.restoreLatestPortableMetadataSnapshot();
    if (mounted) {
      setState(() => _message =
        'Folder recovery complete. Added ${result['documentsAdded']} document records; '
        '${result['documentsLinked']} PDFs linked; '
        '${result['pdfsMissing']} PDF(s) need relinking. '
        'Existing data was retained.');
    }
  });

  Future<void> _openSearchResult(Map<String, Object?> result) async {
    final uri = result['storage_uri']?.toString() ?? '';
    if (uri.isEmpty) return;
    try {
      if (uri.startsWith('content://') || uri.startsWith('file://')) {
        await StorageLocationService.instance.openPdf(uri);
      } else {
        await OpenFilex.open(uri);
      }
    } catch (error) {
      if (mounted) setState(() => _message = 'Could not open matching PDF: $error');
    }
  }

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
    final selected = <String>{};
    await showDialog<void>(context: context, builder: (dialogContext) => StatefulBuilder(
      builder: (context, refresh) => AlertDialog(
        title: const Text('Duplicate PDFs'),
        content: SizedBox(width: 440, height: 380, child: Column(children: [
          const Text('Open each file to compare it. Select copies you want to move to Recycle Bin.'),
          const SizedBox(height: 8),
          Expanded(child: ListView.separated(
            itemCount: docs.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final doc = docs[index];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Checkbox(value: selected.contains(doc.id), onChanged: (value) => refresh(() {
                  if (value == true) { selected.add(doc.id); } else { selected.remove(doc.id); }
                })),
                title: Text('${doc.name}.pdf', maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(_formatSize(doc.sizeBytes)),
                onTap: () async {
                  final uri = doc.storagePath;
                  if (uri.startsWith('content://') || uri.startsWith('file://')) {
                    await StorageLocationService.instance.openPdf(uri);
                  } else {
                    await OpenFilex.open(uri);
                  }
                },
                trailing: PopupMenuButton<String>(
                  onSelected: (action) async {
                    if (action == 'open') {
                      final uri = doc.storagePath;
                      if (uri.startsWith('content://') || uri.startsWith('file://')) {
                        await StorageLocationService.instance.openPdf(uri);
                      } else { await OpenFilex.open(uri); }
                    } else if (action == 'share') {
                      await _tools.shareStoredPdf(doc.storagePath, '${doc.name}.pdf');
                    } else if (action == 'trash') {
                      await DocumentRepository().moveToTrash(doc);
                      refresh(() => selected.remove(doc.id));
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'open', child: Text('Open PDF')),
                    PopupMenuItem(value: 'share', child: Text('Share PDF')),
                    PopupMenuItem(value: 'trash', child: Text('Move to Recycle Bin')),
                  ],
                ),
              );
            },
          )),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close')),
          FilledButton.tonal(
            onPressed: selected.isEmpty ? null : () async {
              final targets = docs.where((d) => selected.contains(d.id)).toList();
              for (final doc in targets) { await DocumentRepository().moveToTrash(doc); }
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              if (mounted) setState(() => _message = 'Moved ${targets.length} duplicate PDF(s) to Recycle Bin.');
            },
            child: Text('Delete selected (${selected.length})'),
          ),
        ],
      ),
    ));
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _showDuplicates() async {
    final groups = await _tools.findExactDuplicates();
    if (!mounted) return;
    await showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: const Text('Duplicate review'),
      content: SizedBox(width: 420, child: groups.isEmpty
        ? const Text('No duplicate PDF found.')
        : ListView(shrinkWrap: true, children: groups.map((g) => ListTile(
            title: Text('${g['copies']} matching PDF files'),
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
            title: const Text('OCR Search Inside PDF'),
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
                subtitle: Text('Open PDF · Text match at character ${r['match_position']}'), onTap: () => _openSearchResult(r))),
            ],
          ])),
          const Divider(height: 1),
          ListTile(leading: const Icon(Icons.copy_all_outlined),
            title: const Text('Duplicate review'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _showDuplicates),
        ])),
      ],
      if (widget.section == 'backup' || widget.section == 'restore' || widget.section == 'backup_restore') Card(child: Column(children: [
        ListTile(leading: const Icon(Icons.backup_outlined), title: const Text('Create backup'),
          subtitle: const Text('Save PDFs, folders, reminders, tags and settings into one ZIP file.'),
          trailing: const Icon(Icons.chevron_right), onTap: _busy ? null : _backup),
        const Divider(height: 1),
        ListTile(leading: const Icon(Icons.settings_backup_restore_outlined), title: const Text('Restore backup'),
          subtitle: const Text('Choose a DocsGrid backup ZIP from this phone or another storage location.'),
          trailing: const Icon(Icons.chevron_right), onTap: _busy ? null : _restoreBackup),
      ])),
    ],
  );
}
