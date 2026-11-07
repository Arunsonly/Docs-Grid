import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../data/document_repository.dart';
import '../../categories/data/category_repository.dart';
import '../../folders/data/folder_repository.dart';

class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key, this.favoritesOnly = false});
  final bool favoritesOnly;

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  final _repository = DocumentRepository();
  final _categoryRepository = CategoryRepository();
  final _folderRepository = FolderRepository();
  final _search = TextEditingController();
  List<DocumentRecord> _documents = [];
  bool _loading = true;
  bool _importing = false;
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
      final docs = await _repository.list(
        query: _search.text,
        favoritesOnly: widget.favoritesOnly,
      );
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

  Future<void> _import() async {
    setState(() => _importing = true);
    try {
      final result = await _repository.importPdfs();
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(
          'Added ${result.added} · Duplicates ${result.duplicates} · Failed ${result.failed}',
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

  Future<void> _open(DocumentRecord document) async {
    final file = File(document.storagePath);
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PDF file is missing from local storage.')),
      );
      return;
    }
    await _repository.markOpened(document);
    final result = await OpenFilex.open(document.storagePath);
    if (mounted && result.type != ResultType.done) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message.isEmpty ? 'No PDF viewer is available.' : result.message)),
      );
    }
    await _load();
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
        if (!widget.favoritesOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    decoration: InputDecoration(
                      hintText: 'Search PDF names',
                      prefixIcon: const Icon(Icons.search),
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

  Widget _emptyState() => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.picture_as_pdf_outlined, size: 58),
          const SizedBox(height: 12),
          Text(widget.favoritesOnly ? 'No saved PDFs yet' : 'Your library is empty',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          const Text('Import PDF files from your phone to get started.', textAlign: TextAlign.center),
          if (!widget.favoritesOnly) ...[
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: _importing ? null : _import,
              icon: const Icon(Icons.add), label: const Text('Import PDFs')),
          ],
        ],
      ),
    ),
  );

  Widget _documentTile(DocumentRecord document) {
    final file = File(document.storagePath);
    return Card(
      elevation: 0,
      child: ListTile(
        onTap: () => _open(document),
        leading: const CircleAvatar(child: Icon(Icons.picture_as_pdf_outlined)),
        title: Text('${document.name}.pdf', maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text([
          _size(document.sizeBytes),
          document.categoryName ?? 'Uncategorised',
          if (document.tagNames.isNotEmpty) document.tagNames.join(', '),
          file.existsSync() ? 'On this device' : 'File missing',
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
            } else if (value == 'trash') {
              await _trash(document);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'favorite',
              child: Text(document.isFavorite ? 'Remove from Saved' : 'Add to Saved')),
            const PopupMenuItem(value: 'category', child: Text('Set category')),
            const PopupMenuItem(value: 'move', child: Text('Move to folder')),
            const PopupMenuItem(value: 'tags', child: Text('Edit tags')),
            const PopupMenuItem(value: 'rename', child: Text('Rename')),
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
