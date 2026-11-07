import 'package:flutter/material.dart';

import '../data/folder_repository.dart';
import '../domain/folder.dart';

class FoldersScreen extends StatefulWidget {
  const FoldersScreen({super.key});

  @override
  State<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends State<FoldersScreen> {
  final FolderRepository _repository = FolderRepository();
  final List<Folder> _ancestors = [];
  String? _currentFolderId;
  String _currentTitle = 'Folders';
  late Future<List<Folder>> _foldersFuture;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _foldersFuture = _repository.childrenOf(_currentFolderId);
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
        _goToRoot();
        return;
      }
      final folder = _ancestors[index];
      _ancestors.removeRange(index + 1, _ancestors.length);
      _currentFolderId = folder.id;
      _currentTitle = folder.name;
      _load();
    });
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
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.error_outline, size: 40),
                    const SizedBox(height: 8),
                    const Text('Could not load folders.'),
                    TextButton(onPressed: _refresh, child: const Text('Try again')),
                  ]),
                );
              }
              final folders = snapshot.data ?? [];
              if (folders.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.folder_open_outlined, size: 52),
                      const SizedBox(height: 12),
                      Text(_currentFolderId == null ? 'No folders yet' : 'This folder is empty',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 6),
                      const Text('Create a folder to organise your PDFs.', textAlign: TextAlign.center),
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
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  itemCount: folders.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (context, index) {
                    final folder = folders[index];
                    return Card(
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
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
