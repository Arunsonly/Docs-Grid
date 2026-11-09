import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../../documents/data/document_repository.dart';
import '../../tools/document_tools_service.dart';
import '../../../core/storage/storage_location_service.dart';
import '../../reminders/data/reminder_repository.dart';
import '../../categories/data/category_repository.dart';

import '../data/folder_repository.dart';
import '../domain/folder.dart';

class FoldersScreen extends StatefulWidget {
  const FoldersScreen({super.key});

  @override
  State<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends State<FoldersScreen> {
  final FolderRepository _repository = FolderRepository();
  final DocumentRepository _documents = DocumentRepository();
  final CategoryRepository _categories = CategoryRepository();
  final List<Folder> _ancestors = [];
  String? _currentFolderId;
  String _currentTitle = 'Folders';
  final Set<String> _selectedDocumentIds = <String>{};
  late Future<List<Folder>> _foldersFuture;
  late Future<List<DocumentRecord>> _documentsFuture;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _foldersFuture = _repository.childrenOf(_currentFolderId);
    _documentsFuture = _documents.listInFolder(_currentFolderId);
  }

  Future<void> _refresh() async {
    setState(_load);
    // Wait for both sections to settle. FutureBuilder renders any errors;
    // swallowing here prevents a failed refresh from escaping the indicator.
    try {
      await Future.wait<Object?>([_foldersFuture, _documentsFuture]);
    } catch (_) {
      // The corresponding FutureBuilder displays the actionable error state.
    }
  }

  Future<void> _openFolder(Folder folder) async {
    setState(() {
      _ancestors.add(folder);
      _currentFolderId = folder.id;
      _currentTitle = folder.name;
      _load();
    });
  }

  void _goToRoot() {
    setState(() {
      _ancestors.clear();
      _currentFolderId = null;
      _currentTitle = 'Folders';
      _load();
    });
  }

  void _goToAncestor(int index) {
    setState(() {
      if (index < 0) {
        _ancestors.clear();
        _currentFolderId = null;
        _currentTitle = 'Folders';
        _load();
        return;
      }
      final folder = _ancestors[index];
      _ancestors.removeRange(index + 1, _ancestors.length);
      _currentFolderId = folder.id;
      _currentTitle = folder.name;
      _load();
    });
  }


  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<String?> _askName({String title = 'New folder', String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Folder name',
            hintText: 'e.g. Insurance',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
        ],
      ),
    );
    // showDialog completes as soon as the route is popped; wait for the
    // reverse transition's frame before disposing the TextField controller.
    await WidgetsBinding.instance.endOfFrame;
    controller.dispose();
    return result?.trim();
  }

  Future<ImportDecision?> _reviewSinglePdf(
    String suggestedName,
    String? suggestedCategoryId,
    List<ImportCategoryOption> categories,
  ) async {
    final allFolders = await _repository.allFoldersWithPaths();
    if (!mounted) return null;
    final nameController = TextEditingController(text: suggestedName);
    String? destinationId = _currentFolderId;
    final result = await showDialog<ImportDecision>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, refresh) => AlertDialog(
          scrollable: true,
          title: const Text('Add PDF to DocsGrid'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'PDF name',
                suffixText: '.pdf',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String?>(
              initialValue: destinationId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Destination folder',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('My Documents (root)'),
                ),
                for (final option in allFolders)
                  DropdownMenuItem<String?>(
                    value: option.folder.id,
                    child: Text(option.path, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (value) => refresh(() => destinationId = value),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('New folder'),
                onPressed: () async {
                  final newName = await _askName();
                  if (newName == null || newName.isEmpty || !dialogContext.mounted) return;
                  try {
                    final created = await _repository.create(
                      name: newName,
                      parentId: destinationId,
                    );
                    final updated = await _repository.allFoldersWithPaths();
                    refresh(() {
                      destinationId = created.id;
                      allFolders
                        ..clear()
                        ..addAll(updated);
                    });
                  } catch (error) {
                    if (dialogContext.mounted) {
                      ScaffoldMessenger.of(dialogContext).showSnackBar(
                        SnackBar(content: Text(error.toString())),
                      );
                    }
                  }
                },
              ),
            ),
          ]),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                Navigator.pop(dialogContext, ImportDecision(
                  name: name,
                  categoryId: suggestedCategoryId,
                ));
              },
              child: const Text('Save PDF'),
            ),
          ],
        ),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    nameController.dispose();
    if (result == null) return null;
    // The destination is captured by the dialog state and applied by the
    // repository's import transaction through this one-file review result.
    return ImportDecision(
      name: result.name,
      categoryId: destinationId == _currentFolderId
          ? result.categoryId
          : result.categoryId,
    );
  }

  Future<void> _showFolderTree() async {
    final options = await _repository.allFoldersWithPaths();
    if (!mounted) return;
    final folders = options.map((option) => option.folder).toList(growable: false);
    final byParent = <String?, List<Folder>>{};
    for (final folder in folders) {
      byParent.putIfAbsent(folder.parentId, () => <Folder>[]).add(folder);
    }
    final selectedId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, refresh) {
          final expanded = <String>{};
          Widget buildNode(Folder folder, int depth) {
            final children = byParent[folder.id] ?? const <Folder>[];
            final isExpanded = expanded.contains(folder.id);
            final isCurrent = folder.id == _currentFolderId;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.only(left: 12.0 + depth * 18.0, right: 12),
                  leading: Icon(children.isEmpty
                      ? Icons.folder_outlined
                      : isExpanded ? Icons.folder_open_outlined : Icons.folder_outlined),
                  title: Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  selected: isCurrent,
                  trailing: children.isEmpty ? null : IconButton(
                    tooltip: isExpanded ? 'Collapse folder' : 'Expand folder',
                    icon: Icon(isExpanded ? Icons.expand_less : Icons.expand_more),
                    onPressed: () => refresh(() {
                      if (isExpanded) {
                        expanded.remove(folder.id);
                      } else {
                        expanded.add(folder.id);
                      }
                    }),
                  ),
                  onTap: () => Navigator.pop(sheetContext, folder.id),
                ),
                if (isExpanded)
                  for (final child in children) buildNode(child, depth + 1),
              ],
            );
          }
          return SafeArea(
            child: FractionallySizedBox(
              heightFactor: 0.78,
              child: Column(
                children: [
                  const ListTile(
                    title: Text('Browse folders', style: TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('Tap a folder to open it; use arrows to expand subfolders.'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.home_outlined),
                    title: const Text('Folders (root)'),
                    selected: _currentFolderId == null,
                    onTap: () => Navigator.pop(sheetContext, ''),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView(
                      key: const PageStorageKey('docsgrid-folder-tree'),
                      children: [
                        for (final root in byParent[null] ?? const <Folder>[])
                          buildNode(root, 0),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (!mounted || selectedId == null) return;
    if (selectedId.isEmpty) {
      _goToRoot();
      return;
    }
    final selected = folders.where((folder) => folder.id == selectedId).firstOrNull;
    if (selected != null) await _openFolder(selected);
  }

  Future<void> _createFolder() async {
    final name = await _askName();
    if (!mounted || name == null || name.isEmpty) return;
    final parentId = _currentFolderId;
    try {
      await _repository.create(name: name, parentId: parentId);
      if (!mounted) return;
      setState(_load);
      _message('Folder created.');
    } catch (error) {
      if (!mounted) return;
      _message(error.toString().replaceFirst('Invalid argument(s): ', ''));
    }
  }

  Future<void> _renameFolder(Folder folder) async {
    final name = await _askName(title: 'Rename folder', initial: folder.name);
    if (name == null) return;
    try {
      await _repository.rename(folder.id, name);
      if (!mounted) return;
      if (_currentFolderId == folder.id) _currentTitle = name.trim();
      setState(_load);
      _message('Folder renamed.');
    } catch (error) {
      _message(error.toString().replaceFirst('Invalid argument(s): ', ''));
    }
  }

  Future<void> _deleteFolder(Folder folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete empty folder?'),
        content: Text('“${folder.name}” can be deleted only when it has no subfolders or documents.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton.tonal(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _repository.deleteEmpty(folder.id);
      if (!mounted) return;
      setState(_load);
      _message('Folder deleted.');
    } catch (error) {
      _message(error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> _moveSelected(List<DocumentRecord> all) async {
    final selected = all.where((d) => _selectedDocumentIds.contains(d.id)).toList();
    if (selected.isEmpty) return;
    final folders = await _repository.allFoldersWithPaths();
    if (!mounted) return;
    final destination = await showModalBottomSheet<String>(
      context: context, showDragHandle: true,
      builder: (ctx) => SafeArea(child: ListView(shrinkWrap: true, children: [
        const ListTile(title: Text('Move selected PDFs to')),
        ListTile(leading: const Icon(Icons.home_outlined), title: const Text('My Documents (root)'), onTap: () => Navigator.pop(ctx, '')),
        for (final folder in folders)
          ListTile(leading: const Icon(Icons.folder_outlined), title: Text(folder.path), onTap: () => Navigator.pop(ctx, folder.folder.id)),
      ])),
    );
    if (destination == null) return;
    final result = await _documents.moveManyToFolder(selected, destination.isEmpty ? null : destination);
    if (!mounted) return;
    setState(_selectedDocumentIds.clear);
    await _refresh();
    final failures = result['failures'] as List<String>;
    _message('Moved ${result['moved']} PDF(s). ${failures.length} failed.');
  }

  Future<void> _addReminder(DocumentRecord document) async {
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
    if (saved != true) return;
    await ReminderRepository().create(title: reminderTitle, note: reminderNote, remindAt: selected, documentId: document.id);
    if (mounted) _message('Reminder saved for this PDF.');
  }

  Future<void> _chooseCategory(DocumentRecord document) async {
    final categories = await _categories.listCategories();
    if (!mounted) return;
    final selected = await showDialog<String?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Set category'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Uncategorised')),
          for (final category in categories)
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, category.id), child: Text(category.name)),
        ],
      ),
    );
    if (selected == null) return;
    await _categories.setDocumentCategory(document.id, selected.isEmpty ? null : selected);
    await _refresh();
  }

  Future<void> _editTags(DocumentRecord document) async {
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
    if (result == null) return;
    await _categories.setDocumentTags(document.id, result.toList());
    await _refresh();
  }

  Future<void> _renamePdf(DocumentRecord document) async {
    final controller = TextEditingController(text: document.name);
    final value = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Rename PDF'),
      content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'File name', suffixText: '.pdf')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
      ],
    ));
    await WidgetsBinding.instance.endOfFrame;
    controller.dispose();
    if (value == null) return;
    await _documents.rename(document, value);
    await _refresh();
  }

  Future<void> _moveOne(DocumentRecord document) async {
    final folders = await _repository.allFoldersWithPaths();
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
    await _documents.moveToFolder(document, destination.isEmpty ? null : destination);
    await _refresh();
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _ancestors.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _ancestors.isNotEmpty) {
          _goToAncestor(_ancestors.length - 2);
        }
      },
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_selectedDocumentIds.isNotEmpty)
          FutureBuilder<List<DocumentRecord>>(
            future: _documentsFuture,
            builder: (context, snapshot) {
              final all = snapshot.data ?? const <DocumentRecord>[];
              return Material(
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: Row(children: [
                  IconButton(tooltip: 'Clear selection', onPressed: () => setState(_selectedDocumentIds.clear), icon: const Icon(Icons.close)),
                  Expanded(child: Text('${_selectedDocumentIds.length} selected')),
                  IconButton(tooltip: 'Select all', onPressed: () => setState(() => _selectedDocumentIds.addAll(all.map((d) => d.id))), icon: const Icon(Icons.select_all)),
                  IconButton(tooltip: 'Share selected', onPressed: () async {
                    final selected = all.where((d) => _selectedDocumentIds.contains(d.id)).toList();
                    if (selected.isEmpty) return;
                    await DocumentToolsService().shareManyStoredPdfs(selected.map((d) => d.storagePath).toList(), selected.map((d) => '${d.name}.pdf').toList());
                  }, icon: const Icon(Icons.share_outlined)),
                  IconButton(tooltip: 'Move selected to folder', onPressed: () => _moveSelected(all), icon: const Icon(Icons.drive_file_move_outlined)),
                  IconButton(tooltip: 'Move selected to Recycle Bin', onPressed: () async {
                    final selected = all.where((d) => _selectedDocumentIds.contains(d.id)).toList();
                    if (selected.isEmpty) return;
                    await _documents.moveManyToTrash(selected);
                    if (!mounted) return;
                    setState(_selectedDocumentIds.clear);
                    await _refresh();
                  }, icon: const Icon(Icons.delete_outline)),
                ]),
              );
            },
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _showFolderTree,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(_currentTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.arrow_drop_down, size: 24),
                      ],
                    ),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Folder actions',
                icon: const Icon(Icons.more_vert),
                onSelected: (action) async {
                  if (action == 'add_pdf') {
                    final result = await _documents.importPdfs(
                      targetFolderId: _currentFolderId,
                      review: _reviewSinglePdf,
                    );
                    await _refresh();
                    if (mounted) _message('Added ${result.added} · Duplicates ${result.duplicates}');
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'add_pdf',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.picture_as_pdf_outlined),
                      title: Text('Add PDF to this folder'),
                    ),
                  ),
                ],
              ),
              IconButton(
                tooltip: 'Create folder',
                onPressed: _createFolder,
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
            ],
          ),
        ),
        if (_ancestors.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                TextButton.icon(
                  onPressed: _goToRoot,
                  icon: const Icon(Icons.home_outlined, size: 18),
                  label: const Text('Folders'),
                ),
                for (var i = 0; i < _ancestors.length; i++) ...[
                  const Icon(Icons.chevron_right, size: 18),
                  TextButton(
                    onPressed: () => _goToAncestor(i),
                    child: Text(_ancestors[i].name),
                  ),
                ],
              ],
            ),
          ),
        Expanded(
          child: FutureBuilder<List<Folder>>(
            future: _foldersFuture,
            builder: (context, folderSnapshot) {
              if (folderSnapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (folderSnapshot.hasError) {
                return Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.error_outline, size: 40),
                    const SizedBox(height: 8),
                    const Text('Could not load folders.'),
                    TextButton(onPressed: _refresh, child: const Text('Try again')),
                  ]),
                );
              }
              final folders = folderSnapshot.data ?? const <Folder>[];
              return FutureBuilder<List<DocumentRecord>>(
                future: _documentsFuture,
                builder: (context, documentSnapshot) {
                  if (documentSnapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (documentSnapshot.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.error_outline, size: 40),
                            const SizedBox(height: 8),
                            const Text('Could not load PDFs.'),
                            const SizedBox(height: 4),
                            Text(
                              '${documentSnapshot.error}',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            FilledButton.icon(
                              onPressed: _refresh,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Try again'),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  final documents = documentSnapshot.data ?? const <DocumentRecord>[];
                  if (folders.isEmpty && documents.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.folder_open_outlined, size: 52),
                          const SizedBox(height: 12),
                          Text(_currentFolderId == null ? 'No folders or PDFs yet' : 'This folder is empty',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 6),
                          const Text('Create a folder or import a PDF to get started.', textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _createFolder,
                            icon: const Icon(Icons.create_new_folder_outlined),
                            label: const Text('Create folder'),
                          ),
                        ]),
                      ),
                    );
                  }
                  return RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                      children: [
                        if (folders.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                            child: Text('FOLDERS', style: Theme.of(context).textTheme.labelLarge),
                          ),
                          for (final folder in folders)
                            Card(
                              elevation: 0,
                              child: ListTile(
                                leading: const CircleAvatar(child: Icon(Icons.folder_outlined)),
                                title: Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: const Text('Folder'),
                                onTap: () => _openFolder(folder),
                                trailing: PopupMenuButton<String>(
                                  tooltip: 'Folder actions',
                                  onSelected: (value) {
                                    if (value == 'rename') _renameFolder(folder);
                                    if (value == 'delete') _deleteFolder(folder);
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                                  ],
                                ),
                              ),
                            ),
                        ],
                        if (documents.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(4, 18, 4, 4),
                            child: Text('PDF DOCUMENTS', style: Theme.of(context).textTheme.labelLarge),
                          ),
                          for (final document in documents)
                            Card(
                              elevation: 0,
                              child: ListTile(
                                leading: _selectedDocumentIds.isNotEmpty
                                    ? Checkbox(value: _selectedDocumentIds.contains(document.id), onChanged: (_) => setState(() { if (!_selectedDocumentIds.add(document.id)) _selectedDocumentIds.remove(document.id); }))
                                    : const Icon(Icons.picture_as_pdf_outlined),
                                title: Tooltip(
                                  message: '${document.name}.pdf',
                                  triggerMode: TooltipTriggerMode.longPress,
                                  waitDuration: const Duration(milliseconds: 450),
                                  child: Text('${document.name}.pdf', maxLines: 1, overflow: TextOverflow.ellipsis),
                                ),
                                subtitle: Text(_size(document.sizeBytes)),
                                onTap: () async {
                                  if (_selectedDocumentIds.isNotEmpty) {
                                    setState(() { if (!_selectedDocumentIds.add(document.id)) _selectedDocumentIds.remove(document.id); });
                                    return;
                                  }
                                  final shared = document.storagePath.startsWith('content://') ||
                                      document.storagePath.startsWith('file://');
                                  if (!shared && !await File(document.storagePath).exists()) {
                                    if (mounted) _message('PDF file is missing from local storage.');
                                    return;
                                  }
                                  await _documents.markOpened(document);
                                  if (shared) {
                                    await StorageLocationService.instance.openPdf(document.storagePath);
                                  } else {
                                    await OpenFilex.open(document.storagePath);
                                  }
                                },
                                trailing: PopupMenuButton<String>(
                                  tooltip: 'PDF actions',
                                  onSelected: (action) async {
                                    try {
                                      if (action == 'share') await DocumentToolsService().shareStoredPdf(document.storagePath, '${document.name}.pdf');
                                      if (action == 'favorite') await _documents.setFavorite(document, !document.isFavorite);
                                      if (action == 'category') await _chooseCategory(document);
                                      if (action == 'tags') await _editTags(document);
                                      if (action == 'rename') await _renamePdf(document);
                                      if (action == 'move') await _moveOne(document);
                                      if (action == 'reminder') await _addReminder(document);
                                      if (action == 'trash') await _documents.moveToTrash(document);
                                      if (mounted) await _refresh();
                                    } catch (error) {
                                      if (mounted) _message('Action failed: $error');
                                    }
                                  },
                                  itemBuilder: (_) => [
                                    const PopupMenuItem(value: 'share', child: Text('Share PDF')),
                                    PopupMenuItem(value: 'favorite', child: Text(document.isFavorite ? 'Remove from Star' : 'Add to Star')),
                                    const PopupMenuItem(value: 'category', child: Text('Set category')),
                                    const PopupMenuItem(value: 'tags', child: Text('Edit tags')),
                                    const PopupMenuItem(value: 'rename', child: Text('Rename')),
                                    const PopupMenuItem(value: 'move', child: Text('Move to folder')),
                                    const PopupMenuItem(value: 'reminder', child: Text('Add to reminder')),
                                    const PopupMenuItem(value: 'trash', child: Text('Move to Recycle Bin')),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ],
                    ),
                  );
                },
              );
            },
          ),
        )
      ],
      ),
    );
  }
}
