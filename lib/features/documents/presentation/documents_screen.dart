import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../data/document_repository.dart';
import '../../../core/storage/storage_location_service.dart';
import '../../categories/data/category_repository.dart';
import '../../folders/data/folder_repository.dart';
import '../../tools/document_tools_service.dart';
import '../../reminders/data/reminder_repository.dart';

class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key, this.favoritesOnly = false, this.recentOnly = false});
  final bool favoritesOnly;
  final bool recentOnly;

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  final _repository = DocumentRepository();
  final _categoryRepository = CategoryRepository();
  final _folderRepository = FolderRepository();
  final _tools = DocumentToolsService();
  final _search = TextEditingController();
  List<DocumentRecord> _documents = [];
  bool _loading = true;
  bool _importing = false;
  bool _searchInsideText = false;
  final Set<String> _selectedIds = <String>{};
  int _loadGeneration = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    _search.addListener(_load);
  }

  @override
  void dispose() {
    _search.removeListener(_load);
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    try {
      var docs = await _repository.list(
        query: _searchInsideText ? '' : _search.text,
        favoritesOnly: widget.favoritesOnly,
        recentOnly: widget.recentOnly,
      );
      if (_searchInsideText && _search.text.trim().isNotEmpty) {
        final matches = await _tools.searchText(_search.text);
        final matchedIds = matches.map((row) => row['id'] as String).toSet();
        docs = docs.where((document) => matchedIds.contains(document.id)).toList();
      }
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _documents = docs;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<ImportDecision?> _reviewImport(
    String suggestedName,
    String? suggestedCategoryId,
    List<ImportCategoryOption> categories,
  ) async {
    final nameController = TextEditingController(text: suggestedName);
    String? selectedCategoryId = suggestedCategoryId;
    final result = await showDialog<ImportDecision>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refreshDialog) => AlertDialog(
          title: const Text('Confirm document details'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Document name', suffixText: '.pdf'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: selectedCategoryId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Suggested category'),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('No category')),
                    for (final category in categories)
                      DropdownMenuItem<String?>(value: category.id, child: Text(category.name)),
                  ],
                  onChanged: (value) => refreshDialog(() => selectedCategoryId = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Skip')),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, ImportDecision(
                name: nameController.text,
                categoryId: selectedCategoryId,
              )),
              child: const Text('Import PDF'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    return result;
  }

  Future<void> _import() async {
    final folders = await _folderRepository.allFoldersWithPaths();
    if (!mounted) return;
    final destination = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Choose destination folder')),
          ListTile(leading: const Icon(Icons.home_outlined), title: const Text('My Documents (root)'), onTap: () => Navigator.pop(sheetContext, '')),
          for (final option in folders)
            ListTile(leading: const Icon(Icons.folder_outlined), title: Text(option.path), onTap: () => Navigator.pop(sheetContext, option.folder.id)),
        ]),
      ),
    );
    if (destination == null || !mounted) return;
    setState(() => _importing = true);
    try {
      final result = await _repository.importPdfs(
        review: _reviewImport,
        targetFolderId: destination.isEmpty ? null : destination,
      );
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(
          'Added ${result.added} · Duplicates ${result.duplicates} · Skipped ${result.skipped} · Failed ${result.failed}',
        )),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import failed: $error')));
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _toggleSelected(DocumentRecord document) {
    setState(() {
      if (!_selectedIds.add(document.id)) _selectedIds.remove(document.id);
    });
  }

  Future<void> _bulkTrash() async {
    final selected = _documents.where((d) => _selectedIds.contains(d.id)).toList();
    if (selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move selected PDFs to Recycle Bin?'),
        content: Text('${selected.length} PDFs will be hidden. Files will not be erased.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Move')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repository.moveManyToTrash(selected);
    if (!mounted) return;
    setState(_selectedIds.clear);
    await _load();
  }

  Future<void> _bulkShare() async {
    final selected = _documents.where((d) => _selectedIds.contains(d.id)).toList();
    if (selected.isEmpty) return;
    try {
      await _tools.shareManyStoredPdfs(
        selected.map((d) => d.storagePath).toList(),
        selected.map((d) => '${d.name}.pdf').toList(),
      );
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share selected PDFs: $error')));
    } finally {
      if (mounted) setState(_selectedIds.clear);
    }
  }
  Future<void> _bulkMove() async {
    final selected = _documents.where((d) => _selectedIds.contains(d.id)).toList();
    if (selected.isEmpty) return;
    final folders = await _folderRepository.allFoldersWithPaths();
    if (!mounted) return;
    final destination = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Move selected PDFs to')),
            ListTile(leading: const Icon(Icons.home_outlined), title: const Text('Root / No folder'), onTap: () => Navigator.pop(sheetContext, '')),
            for (final option in folders)
              ListTile(leading: const Icon(Icons.folder_outlined), title: Text(option.path), onTap: () => Navigator.pop(sheetContext, option.folder.id)),
          ],
        ),
      ),
    );
    if (destination == null) return;
    final result = await _repository.moveManyToFolder(selected, destination.isEmpty ? null : destination);
    if (!mounted) return;
    setState(_selectedIds.clear);
    await _load();
    if (!mounted) return;
    final failures = result['failures'] as List<String>;
    final failureSummary = failures.isEmpty ? '' : ' · ${failures.length} failed';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Moved ${result['moved']} of ${selected.length} PDFs$failureSummary'),
    ));
  }

  Future<void> _open(DocumentRecord document) async {
    final isSafUri = document.storagePath.startsWith('content://') || document.storagePath.startsWith('file://');
    if (!isSafUri) {
      final file = File(document.storagePath);
      if (!await file.exists()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PDF file is missing from local storage.')),
        );
        return;
      }
    }
    await _repository.markOpened(document);
    if (isSafUri) {
      try {
        await StorageLocationService.instance.openPdf(document.storagePath);
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open PDF: $error')),
          );
        }
      }
    } else {
      final result = await OpenFilex.open(document.storagePath);
      if (mounted && result.type != ResultType.done) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.message.isEmpty ? 'No PDF viewer is available.' : result.message)),
        );
      }
    }
    await _load();
  }


  Future<void> _share(DocumentRecord document) async {
    try {
      await _tools.shareStoredPdf(document.storagePath, '${document.name}.pdf');
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not share PDF: $error')),
        );
      }
    }
  }

  Future<void> _relink(DocumentRecord document) async {
    try {
      await _repository.relinkDocument(document);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PDF relinked and verified successfully.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF recovery failed: $error')),
        );
      }
    }
  }

  Future<void> _rename(DocumentRecord document) async {
    final controller = TextEditingController(text: document.name);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename PDF'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'File name', suffixText: '.pdf'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    try {
      await _repository.rename(document, value);
      await _load();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _addReminder(DocumentRecord document) async {
    final title = TextEditingController(text: 'Renewal - ${document.name}');
    final note = TextEditingController();
    var selected = DateTime.now().add(const Duration(days: 1));
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          scrollable: true,
          title: const Text('Add to reminder'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, decoration: const InputDecoration(labelText: 'Reminder title')),
            TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'Note (optional)')),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Date & time'),
              subtitle: Text('${selected.day.toString().padLeft(2, '0')}/${selected.month.toString().padLeft(2, '0')}/${selected.year} · ${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}'),
              onTap: () async {
                final date = await showDatePicker(context: context, initialDate: selected, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 3650)));
                if (date == null || !context.mounted) return;
                final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(selected));
                if (time != null) refresh(() => selected = DateTime(date.year, date.month, date.day, time.hour, time.minute));
              },
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(onPressed: () {
              if (title.text.trim().isNotEmpty && selected.isAfter(DateTime.now())) Navigator.pop(dialogContext, true);
            }, child: const Text('Save')),
          ],
        ),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    final reminderTitle = title.text.trim();
    final reminderNote = note.text.trim();
    title.dispose();
    note.dispose();
    if (saved != true) return;
    try {
      await ReminderRepository().create(
        title: reminderTitle,
        note: reminderNote,
        remindAt: selected,
        documentId: document.id,
      );
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reminder saved for this PDF.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save reminder: $error')));
    }
  }

  Future<void> _showTrash() async {
    var trashed = await _repository.listTrash();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refreshDialog) => AlertDialog(
          title: const Text('Recycle Bin'),
          content: SizedBox(
            width: double.maxFinite,
            child: trashed.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text('Recycle Bin is empty.'),
                  )
                : SizedBox(
                    height: 340,
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: trashed.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final document = trashed[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.picture_as_pdf_outlined),
                          title: Text('${document.name}.pdf',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: const Text('PDF moved to Recycle Bin'),
                          trailing: PopupMenuButton<String>(
                            onSelected: (action) async {
                              if (action == 'restore') {
                                await _repository.restoreFromTrash(document);
                                refreshDialog(() => trashed.removeAt(index));
                                await _load();
                              } else if (action == 'delete') {
                                final confirmed = await showDialog<bool>(
                                  context: dialogContext,
                                  builder: (confirmContext) => AlertDialog(
                                    title: const Text('Delete permanently?'),
                                    content: Text('${document.name}.pdf will be erased from this device.'),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(confirmContext, false),
                                        child: const Text('Cancel'),
                                      ),
                                      FilledButton(
                                        onPressed: () => Navigator.pop(confirmContext, true),
                                        child: const Text('Delete'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed == true) {
                                  await _repository.permanentlyDelete(document);
                                  refreshDialog(() => trashed.removeAt(index));
                                  await _load();
                                }
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'restore', child: Text('Restore')),
                              PopupMenuItem(value: 'delete', child: Text('Delete permanently')),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _chooseCategory(DocumentRecord document) async {
    final categories = await _categoryRepository.listCategories();
    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Choose category'),
              subtitle: Text('This changes only the document label.'),
            ),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: const Text('No category'),
              onTap: () => Navigator.pop(sheetContext, ''),
            ),
            for (final category in categories)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(category.name),
                trailing: document.categoryId == category.id
                    ? const Icon(Icons.check, color: Colors.green)
                    : null,
                onTap: () => Navigator.pop(sheetContext, category.id),
              ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    await _categoryRepository.setDocumentCategory(
      document.id,
      selected.isEmpty ? null : selected,
    );
    await _load();
  }

  Future<void> _editTags(DocumentRecord document) async {
    final tags = await _categoryRepository.listTags();
    if (!mounted) return;
    final current = await _categoryRepository.tagsForDocument(document.id);
    if (!mounted) return;
    final selected = current.map((tag) => tag.id).toSet();
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, refresh) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(
                  title: Text('Document tags'),
                  subtitle: Text('Select one or more reusable tags.'),
                ),
                if (tags.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('No tags created yet. Add tags in Settings → Categories & tags.'),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 360),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final tag in tags)
                          CheckboxListTile(
                            value: selected.contains(tag.id),
                            title: Text(tag.name),
                            onChanged: (checked) => refresh(() {
                              if (checked == true) {
                                selected.add(tag.id);
                              } else {
                                selected.remove(tag.id);
                              }
                            }),
                          ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(sheetContext, selected),
                      child: const Text('Save tags'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (result == null) return;
    await _categoryRepository.setDocumentTags(document.id, result.toList());
    await _load();
  }

  Future<void> _moveToFolder(DocumentRecord document) async {
    final folders = await _folderRepository.allFoldersWithPaths();
    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Move PDF to folder'),
              subtitle: Text('The PDF stays in the same local library.'),
            ),
            ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('Root / No folder'),
              trailing: document.folderId == null ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(sheetContext, ''),
            ),
            for (final option in folders)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(option.path),
                trailing: document.folderId == option.folder.id
                    ? const Icon(Icons.check, color: Colors.green)
                    : null,
                onTap: () => Navigator.pop(sheetContext, option.folder.id),
              ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    await _repository.moveToFolder(document, selected.isEmpty ? null : selected);
    await _load();
  }

  Future<void> _trash(DocumentRecord document) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move to Recycle Bin?'),
        content: Text('${document.name}.pdf will be hidden from the library. The file is not erased.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Move')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repository.moveToTrash(document);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (_selectedIds.isNotEmpty)
          Material(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(children: [
                IconButton(tooltip: 'Clear selection', onPressed: () => setState(_selectedIds.clear), icon: const Icon(Icons.close)),
                Expanded(child: Text('${_selectedIds.length} selected', style: const TextStyle(fontWeight: FontWeight.w700))),
                IconButton(tooltip: 'Share selected', onPressed: _bulkShare, icon: const Icon(Icons.share_outlined)),
                IconButton(tooltip: _selectedIds.length == _documents.length ? 'Clear all selection' : 'Select all', onPressed: () => setState(() { if (_selectedIds.length == _documents.length) { _selectedIds.clear(); } else { _selectedIds.addAll(_documents.map((d) => d.id)); } }), icon: const Icon(Icons.select_all)),
                IconButton(tooltip: 'Move selected', onPressed: _bulkMove, icon: const Icon(Icons.drive_file_move_outline)),
                IconButton(tooltip: 'Move selected to Recycle Bin', onPressed: _bulkTrash, icon: const Icon(Icons.delete_outline)),
              ]),
            ),
          ),
        if (!widget.favoritesOnly && !widget.recentOnly)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF123B91), Color(0xFF087FC7), Color(0xFF08AFC0)],
              ),
              boxShadow: const [BoxShadow(color: Color(0x220B4B91), blurRadius: 18, offset: Offset(0, 8))],
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('YOUR OFFLINE DRIVE', style: TextStyle(color: Colors.white70, fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text('${_size(_documents.fold<int>(0, (total, document) => total + document.sizeBytes))} occupied', style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(child: _dashboardMetric(Icons.picture_as_pdf_outlined, '${_documents.length}', 'Documents')),
                Expanded(child: _dashboardMetric(Icons.folder_outlined, 'Folders', 'Organised')),
                Expanded(child: _dashboardMetric(Icons.offline_pin_outlined, 'Offline', 'On device')),
              ]),
            ]),
          ),
        if (!widget.favoritesOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    decoration: InputDecoration(
                      hintText: _searchInsideText ? 'Search text inside PDFs' : 'Search PDF names',
                      prefixIcon: PopupMenuButton<String>(
                        tooltip: 'Choose search type',
                        icon: const Icon(Icons.search),
                        onSelected: (value) {
                          setState(() => _searchInsideText = value == 'text');
                          _load();
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(value: 'name', child: Row(children: [Icon(_searchInsideText ? Icons.circle_outlined : Icons.check_circle, size: 18), const SizedBox(width: 8), const Text('File name') ])),
                          PopupMenuItem(value: 'text', child: Row(children: [Icon(_searchInsideText ? Icons.check_circle : Icons.circle_outlined, size: 18), const SizedBox(width: 8), const Text('Text inside PDF') ])),
                        ],
                      ),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(onPressed: _search.clear, icon: const Icon(Icons.close)),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Recycle Bin',
                  onPressed: _showTrash,
                  icon: const Icon(Icons.delete_outline),
                ),
                const SizedBox(width: 4),
                FilledButton.tonalIcon(
                  onPressed: _importing ? null : _import,
                  icon: const Icon(Icons.add),
                  label: const Text('Import'),
                ),
              ],
            ),
          ),
        if (_importing) const LinearProgressIndicator(),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text('Could not load documents\n$_error', textAlign: TextAlign.center))
                  : _documents.isEmpty
                      ? _emptyState()
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
                            itemCount: _documents.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 6),
                            itemBuilder: (context, index) => _documentTile(_documents[index]),
                          ),
                        ),
        ),
      ],
    );
  }

  Widget _dashboardMetric(IconData icon, String value, String label) => Row(
    children: [
      Icon(icon, color: Colors.white, size: 20),
      const SizedBox(width: 6),
      Flexible(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white70, fontSize: 10)),
      ])),
    ],
  );

  Widget _emptyState() => SingleChildScrollView(
    physics: const AlwaysScrollableScrollPhysics(),
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: MediaQuery.sizeOf(context).height * 0.22),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.picture_as_pdf_outlined, size: 48),
              const SizedBox(height: 8),
              Text(widget.favoritesOnly ? 'No starred PDFs yet' : widget.recentOnly ? 'No recently opened PDFs' : 'Your library is empty',
                  style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(widget.recentOnly ? 'Open a PDF and it will appear here.' : 'Import PDF files from your phone to get started.', textAlign: TextAlign.center),
              if (!widget.favoritesOnly && !widget.recentOnly) ...[
                const SizedBox(height: 12),
                FilledButton.icon(onPressed: _importing ? null : _import,
                  icon: const Icon(Icons.add), label: const Text('Import PDFs')),
              ],
            ],
          ),
        ),
      ),
    ),
  );

  Widget _documentTile(DocumentRecord document) {
    final file = File(document.storagePath);
    final selected = _selectedIds.contains(document.id);
    return Card(
      elevation: 0,
      child: ListTile(
        onLongPress: () => _toggleSelected(document),
        onTap: () => _selectedIds.isNotEmpty ? _toggleSelected(document) : _open(document),
        leading: _selectedIds.isNotEmpty
            ? Checkbox(value: selected, onChanged: (_) => _toggleSelected(document))
            : const CircleAvatar(child: Icon(Icons.picture_as_pdf_outlined)),
        title: Text('${document.name}.pdf', maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text([
          _size(document.sizeBytes),
          document.categoryName ?? 'Uncategorised',
          if (document.tagNames.isNotEmpty) document.tagNames.join(', '),
          (document.storagePath.startsWith('content://') || document.storagePath.startsWith('file://') || file.existsSync()) ? 'On this device' : 'File missing',
        ].join(' · ')),
        trailing: PopupMenuButton<String>(
          onSelected: (value) async {
            if (value == 'favorite') {
              await _repository.setFavorite(document, !document.isFavorite);
              await _load();
            } else if (value == 'tags') {
              await _editTags(document);
            } else if (value == 'move') {
              await _moveToFolder(document);
            } else if (value == 'category') {
              await _chooseCategory(document);
            } else if (value == 'rename') {
              await _rename(document);
            } else if (value == 'share') {
              await _share(document);
            } else if (value == 'reminder') {
              await _addReminder(document);
            } else if (value == 'relink') {
              await _relink(document);
            } else if (value == 'trash') {
              await _trash(document);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'favorite',
              child: Text(document.isFavorite ? 'Remove from Star' : 'Add to Star')),
            const PopupMenuItem(value: 'category', child: Text('Set category')),
            const PopupMenuItem(value: 'move', child: Text('Move to folder')),
            const PopupMenuItem(value: 'tags', child: Text('Edit tags')),
            const PopupMenuItem(value: 'rename', child: Text('Rename')),
            const PopupMenuItem(value: 'share', child: Text('Share PDF')),
            const PopupMenuItem(value: 'reminder', child: Text('Add to reminder')), 
            const PopupMenuItem(value: 'relink', child: Text('Relink / Replace PDF')),
            const PopupMenuItem(value: 'trash', child: Text('Move to Recycle Bin')),
          ],
        ),
      ),
    );
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
