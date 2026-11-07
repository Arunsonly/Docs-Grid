import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../../documents/data/document_repository.dart';
import '../../tools/document_tools_service.dart';
import '../../../core/storage/storage_location_service.dart';

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
  final List<Folder> _ancestors = [];
  String? _currentFolderId;
  String _currentTitle = 'Folders';
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
    await _foldersFuture;
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

  Future<void> _showFolderDocuments() async {
    final folderId = _currentFolderId;
    final title = folderId == null ? 'Root PDFs' : 'PDFs in $_currentTitle';
    final documents = await _documents.listInFolder(folderId);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (pageContext) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: documents.isEmpty
              ? const Center(child: Text('No PDFs in this folder yet.'))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: documents.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final document = documents[index];
                    return ListTile(
                      leading: const Icon(Icons.picture_as_pdf_outlined),
                      title: Text('${document.name}.pdf', maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(_size(document.sizeBytes)),
                      onTap: () async {
                        final isSafUri = document.storagePath.startsWith('content://') ||
                            document.storagePath.startsWith('file://');
                        if (!isSafUri && !await File(document.storagePath).exists()) {
                          if (pageContext.mounted) {
                            ScaffoldMessenger.of(pageContext).showSnackBar(
                              const SnackBar(content: Text('PDF file is missing from local storage.')),
                            );
                          }
                          return;
                        }
                        await _documents.markOpened(document);
                        if (isSafUri) {
                          await StorageLocationService.instance.openPdf(document.storagePath);
                        } else {
                          await OpenFilex.open(document.storagePath);
                        }
                      },
                    );
                  },
                ),
        ),
      ),
    );
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
    controller.dispose();
    return result;
  }

  Future<void> _createFolder() async {
    final name = await _askName();
    if (name == null) return;
    try {
      await _repository.create(name: name, parentId: _currentFolderId);
      if (!mounted) return;
      setState(_load);
      _message('Folder created.');
    } catch (error) {
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

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(_currentTitle,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              ),
              IconButton(
                tooltip: 'PDFs in this folder',
                onPressed: _showFolderDocuments,
                icon: const Icon(Icons.picture_as_pdf_outlined),
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
                    return Center(child: Text('Could not load PDFs: ${documentSnapshot.error}'));
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
                                leading: const Icon(Icons.picture_as_pdf_outlined),
                                title: Text('${document.name}.pdf', maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Text(_size(document.sizeBytes)),
                                onTap: () async {
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
                                trailing: IconButton(
                                  tooltip: 'Share PDF',
                                  icon: const Icon(Icons.share_outlined),
                                  onPressed: () async {
                                    try {
                                      await DocumentToolsService().shareStoredPdf(
                                        document.storagePath, '${document.name}.pdf',
                                      );
                                    } catch (error) {
                                      if (mounted) _message('Could not share PDF: $error');
                                    }
                                  },
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
    );
  }
}
