import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import '../../core/database/app_database.dart';
import '../documents/data/document_repository.dart';
import '../categories/data/category_repository.dart';
import '../reminders/data/reminder_repository.dart';
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
  final _categories = CategoryRepository();
  final _search = TextEditingController();
  List<Map<String, Object?>> _results = [];
  bool _busy = false;
  String? _message;
  bool _hasSearched = false;

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
    // Share the on-disk ZIP directly. The platform share sheet lets the user
    // save it to Files/Drive without loading the whole archive into RAM.
    await _tools.shareFile(archive.path, text: 'DocsGrid backup');
    if (mounted) {
      setState(() => _message = 'Backup created. Use the share sheet to save a copy somewhere safe.');
    }
  });

  Future<void> _restoreBackup() => _run(() async {
    final source = await showModalBottomSheet<String>(
      context: context, showDragHandle: true,
      builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const ListTile(title: Text('Choose restore source')),
        ListTile(leading: const Icon(Icons.archive_outlined), title: const Text('Backup ZIP file'),
          subtitle: const Text('From this phone, SD card, USB or cloud storage.'),
          onTap: () => Navigator.pop(ctx, 'zip')),
        ListTile(leading: const Icon(Icons.folder_open_outlined), title: const Text('Existing DocsGrid folder'),
          subtitle: const Text('Recover from a DocsGrid folder copied from another phone.'),
          onTap: () => Navigator.pop(ctx, 'folder')),
      ])),
    );
    if (source == 'folder') {
      await _restorePortableSnapshot();
      return;
    }
    if (source != 'zip') return;
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    if (picked.isEmpty) return;
    final platformFile = picked.single;
    final temporaryCopy = platformFile.path == null;
    final file = temporaryCopy
        ? File(p.join(Directory.systemTemp.path, 'DocsGrid_restore_${DateTime.now().microsecondsSinceEpoch}.zip'))
        : File(platformFile.path!);
    try {
      if (temporaryCopy) {
        await file.writeAsBytes(await platformFile.readAsBytes(), flush: true);
      }
      final count = await _tools.validateBackup(file);
      if (!mounted) return;
      final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: const Text('Restore backup?'),
        content: Text('The archive contains $count PDF file(s). Existing records will be kept; the backup will be added without overwriting your current files.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Restore')),
        ],
      ));
      if (confirmed != true) return;
      final restored = await _tools.restoreBackup(file);
      if (mounted) setState(() => _message = 'Restore completed: $restored PDF file(s) restored and verified.');
    } finally {
      if (temporaryCopy && await file.exists()) await file.delete();
    }
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
    try {
      final rows = await _tools.searchText(_search.text);
      if (mounted) setState(() { _results = rows; _hasSearched = true; _message = null; });
    } catch (error) {
      if (mounted) setState(() => _message = 'Text search failed: $error');
    }
  }

  Future<void> _indexDocuments() => _run(() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('documents',
      columns: ['id', 'name', 'storage_uri', 'extracted_text_status'],
      where: 'deleted_at IS NULL');
    var done = 0;
    var noText = 0;
    var skipped = 0;
    var alreadyIndexed = 0;
    for (final row in rows) {
      if (row['extracted_text_status'] == 'indexed') {
        alreadyIndexed++;
        continue;
      }
      final uri = row['storage_uri'] as String?;
      if (uri == null || uri.isEmpty) {
        skipped++;
        continue;
      }
      try {
        final characters = await _tools.indexPdfTextFromUri(row['id'] as String, uri);
        if (characters == 0) {
          noText++;
        } else {
          done++;
        }
      } catch (_) {
        skipped++;
      }
    }
    if (mounted) {
      setState(() => _message =
        'OCR indexing finished: $done searchable, $noText had no readable text, $alreadyIndexed already indexed, $skipped failed. '
        'Scanned/image-only PDFs may need clearer pages or a supported OCR language.');
    }
  });


  Future<void> _duplicateRename(DocumentRecord document) async {
    final controller = TextEditingController(text: document.name);
    final name = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Rename PDF'),
      content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'File name', suffixText: '.pdf')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
      ],
    ));
    await WidgetsBinding.instance.endOfFrame;
    controller.dispose();
    if (name == null) return;
    await DocumentRepository().rename(document, name);
  }

  Future<void> _duplicateMove(DocumentRecord document) async {
    final folders = await FolderRepository().allFoldersWithPaths();
    if (!mounted) return;
    final destination = await showModalBottomSheet<String>(
      context: context, showDragHandle: true,
      builder: (ctx) => SafeArea(child: ListView(shrinkWrap: true, children: [
        const ListTile(title: Text('Move PDF to folder')),
        ListTile(leading: const Icon(Icons.home_outlined), title: const Text('My Documents (root)'), onTap: () => Navigator.pop(ctx, '')),
        for (final folder in folders)
          ListTile(leading: const Icon(Icons.folder_outlined), title: Text(folder.path), onTap: () => Navigator.pop(ctx, folder.folder.id)),
      ])),
    );
    if (destination == null) return;
    await DocumentRepository().moveToFolder(document, destination.isEmpty ? null : destination);
  }

  Future<void> _duplicateCategory(DocumentRecord document) async {
    final categories = await _categories.listCategories();
    if (!mounted) return;
    final selected = await showDialog<String?>(context: context, builder: (ctx) => SimpleDialog(
      title: const Text('Set category'),
      children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Uncategorised')),
        for (final category in categories)
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, category.id), child: Text(category.name)),
      ],
    ));
    if (selected == null) return;
    await _categories.setDocumentCategory(document.id, selected.isEmpty ? null : selected);
  }

  Future<void> _duplicateTags(DocumentRecord document) async {
    final tags = await _categories.listTags();
    final current = await _categories.tagsForDocument(document.id);
    if (!mounted) return;
    final selected = current.map((tag) => tag.id).toSet();
    final result = await showDialog<Set<String>>(context: context, builder: (ctx) => StatefulBuilder(
      builder: (ctx, refresh) => AlertDialog(
        title: const Text('Edit tags'),
        content: SizedBox(width: 360, child: tags.isEmpty
          ? const Text('Create tags in Category & Tag settings first.')
          : Column(mainAxisSize: MainAxisSize.min, children: [
              for (final tag in tags)
                CheckboxListTile(dense: true, contentPadding: EdgeInsets.zero, value: selected.contains(tag.id),
                  title: Text(tag.name), onChanged: (value) => refresh(() {
                    if (value == true) { selected.add(tag.id); } else { selected.remove(tag.id); }
                  })),
            ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, selected), child: const Text('Save tags')),
        ],
      ),
    ));
    if (result != null) await _categories.setDocumentTags(document.id, result.toList());
  }

  Future<void> _duplicateReminder(DocumentRecord document) async {
    final title = TextEditingController(text: 'Reminder - ${document.name}');
    final note = TextEditingController();
    var selected = DateTime.now().add(const Duration(days: 1));
    final saved = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(
      builder: (ctx, refresh) => AlertDialog(
        scrollable: true, title: const Text('Add to reminder'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, decoration: const InputDecoration(labelText: 'Reminder title')),
          TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'Note (optional)')),
          ListTile(contentPadding: EdgeInsets.zero, title: const Text('Date & time'),
            subtitle: Text('${selected.day.toString().padLeft(2, '0')}/${selected.month.toString().padLeft(2, '0')}/${selected.year} · ${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}'),
            onTap: () async {
              final date = await showDatePicker(context: ctx, initialDate: selected, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 3650)));
              if (date == null || !ctx.mounted) return;
              final time = await showTimePicker(context: ctx, initialTime: TimeOfDay.fromDateTime(selected));
              if (time != null) refresh(() => selected = DateTime(date.year, date.month, date.day, time.hour, time.minute));
            }),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () { if (title.text.trim().isNotEmpty && selected.isAfter(DateTime.now())) Navigator.pop(ctx, true); }, child: const Text('Save')),
        ],
      ),
    ));
    await WidgetsBinding.instance.endOfFrame;
    final reminderTitle = title.text.trim();
    final reminderNote = note.text.trim();
    title.dispose(); note.dispose();
    if (saved == true) await ReminderRepository().create(title: reminderTitle, note: reminderNote, remindAt: selected, documentId: document.id);
  }

  Future<void> _reviewDuplicateGroup(List<String> documentIds, String duplicateType) async {
    if (documentIds.length < 2) return;
    final db = await AppDatabase.instance.database;
    final placeholders = List.filled(documentIds.length, '?').join(',');
    final rows = await db.query('documents',
      where: 'id IN ($placeholders) AND deleted_at IS NULL',
      whereArgs: documentIds,
      orderBy: 'created_at ASC');
    final docs = rows.map(DocumentRecord.fromMap).toList();
    if (docs.length < 2 || !mounted) return;
    await showDialog<void>(context: context, builder: (dialogContext) => StatefulBuilder(
      builder: (context, refresh) => AlertDialog(
        title: Text('Duplicate PDFs · $duplicateType'),
        content: SizedBox(width: 440, height: 380, child: Column(children: [
          const Text('Review each matching PDF. Move unwanted copies to Recycle Bin one at a time.'),
          const SizedBox(height: 8),
          Expanded(child: docs.isEmpty
            ? const Center(child: Text('No remaining duplicates in this group.'))
            : ListView.separated(
              itemCount: docs.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final doc = docs[index];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.picture_as_pdf_outlined),
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
                        final confirmed = await showDialog<bool>(
                          context: dialogContext,
                          builder: (confirmContext) => AlertDialog(
                            title: const Text('Move this copy to Recycle Bin?'),
                            content: Text('${doc.name}.pdf will remain recoverable in Recycle Bin.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(confirmContext, false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.pop(confirmContext, true), child: const Text('Move')),
                            ],
                          ),
                        );
                        if (confirmed == true) {
                          await DocumentRepository().moveToTrash(doc);
                          refresh(() => docs.removeWhere((item) => item.id == doc.id));
                          if (mounted) setState(() => _message = 'Moved one duplicate to Recycle Bin. Remaining matches stay open.');
                        }
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'open', child: Text('Open PDF')),
                      PopupMenuItem(value: 'share', child: Text('Share PDF')),
                      PopupMenuItem(value: 'trash', child: Text('Move this copy to Recycle Bin')),
                    ],
                  ),
                );
              },
            )),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Back'))],
      ),
    ));
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _showDuplicates() async {
    final groups = await _tools.findDuplicateGroups();
    if (!mounted) return;
    await showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: const Text('Check Duplicate File'),
      content: SizedBox(width: 420, child: groups.isEmpty
        ? const Text('No duplicates found. Run OCR indexing first to detect matching scanned/text content.')
        : ListView(shrinkWrap: true, children: groups.map((g) => ListTile(
            leading: Icon(g['duplicate_type'] == 'SHA-256' ? Icons.fingerprint : Icons.text_snippet_outlined),
            title: Text('${g['copies']} matching PDF files · ${g['duplicate_type']}'),
            subtitle: Text((g['names'] ?? '').toString()),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.pop(context);
              final ids = (g['document_ids'] ?? '').toString().split(',').where((id) => id.isNotEmpty).toList();
              _reviewDuplicateGroup(ids, g['duplicate_type'] as String);
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
            const SizedBox(height: 6),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'OCR languages: Android supports English and Hindi. iPhone currently supports Latin-script text only.',
                style: TextStyle(fontSize: 12),
              ),
            ),
            if (_results.isNotEmpty) ...[
              const SizedBox(height: 8),
              ..._results.map((r) => ListTile(dense: true,
                leading: const Icon(Icons.picture_as_pdf_outlined),
                title: Text((r['name'] ?? '').toString()),
                subtitle: Text('Found on page ${r['match_page'] ?? 1} · Tap to open PDF'),
                trailing: IconButton(tooltip: 'Open PDF', icon: const Icon(Icons.open_in_new), onPressed: () => _openSearchResult(r)),
                onTap: () => _openSearchResult(r))),
            ] else if (_hasSearched && _search.text.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              const Align(alignment: Alignment.centerLeft,
                child: Text('No match found in indexed PDFs.')),
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
