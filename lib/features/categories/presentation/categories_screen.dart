import 'package:flutter/material.dart';

import '../data/category_repository.dart';

class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  final _repository = CategoryRepository();
  List<CategoryRecord> _categories = [];
  List<TagRecord> _tags = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _repository.listCategories(),
        _repository.listTags(),
      ]);
      if (!mounted) return;
      setState(() {
        _categories = results[0] as List<CategoryRecord>;
        _tags = results[1] as List<TagRecord>;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<String?> _nameDialog({String title = 'Add name', String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Enter a name'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _addCategory() async {
    final name = await _nameDialog(title: 'New category');
    if (name == null) return;
    try {
      await _repository.createCategory(name);
      await _load();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _renameCategory(CategoryRecord category) async {
    final name = await _nameDialog(title: 'Rename category', initial: category.name);
    if (name == null) return;
    try {
      await _repository.renameCategory(category, name);
      await _load();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _deleteCategory(CategoryRecord category) async {
    final confirmed = await _confirm(
      'Delete category?',
      'Documents in “${category.name}” will remain. Their category will be cleared.',
    );
    if (!confirmed) return;
    try {
      await _repository.deleteCategory(category);
      await _load();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _addTag() async {
    final name = await _nameDialog(title: 'New tag');
    if (name == null) return;
    try {
      await _repository.createTag(name);
      await _load();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _deleteTag(TagRecord tag) async {
    final confirmed = await _confirm(
      'Delete tag?',
      'The tag “${tag.name}” will be removed from all documents.',
    );
    if (!confirmed) return;
    try {
      await _repository.deleteTag(tag);
      await _load();
    } catch (error) {
      _showError(error);
    }
  }

  Future<bool> _confirm(String title, String message) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete')),
            ],
          ),
        ) ??
        false;
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.toString())),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('Could not load categories\n$_error'));

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        children: [
          _sectionHeader('Categories', 'Organise documents by type', Icons.category_outlined, _addCategory),
          const SizedBox(height: 8),
          Card(
            child: _categories.isEmpty
                ? const ListTile(title: Text('No categories'))
                : Column(
                    children: [
                      for (var i = 0; i < _categories.length; i++) ...[
                        if (i > 0) const Divider(height: 1, indent: 16),
                        ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.folder_outlined)),
                          title: Text(_categories[i].name),
                          subtitle: Text(_categories[i].isBuiltIn ? 'Built-in category' : 'Custom category'),
                          trailing: _categories[i].isBuiltIn
                              ? const Icon(Icons.lock_outline, size: 18)
                              : PopupMenuButton<String>(
                                  onSelected: (value) {
                                    if (value == 'rename') _renameCategory(_categories[i]);
                                    if (value == 'delete') _deleteCategory(_categories[i]);
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                                  ],
                                ),
                        ),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 24),
          _sectionHeader('Tags', 'Add labels that can be reused', Icons.sell_outlined, _addTag),
          const SizedBox(height: 8),
          Card(
            child: _tags.isEmpty
                ? const ListTile(title: Text('No tags yet'), subtitle: Text('Create tags to label documents.'))
                : Padding(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final tag in _tags)
                          InputChip(
                            label: Text(tag.name),
                            onDeleted: () => _deleteTag(tag),
                          ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Categories and tags are stored locally on this device. They are not uploaded to a server.',
            style: TextStyle(color: Colors.black54, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, String subtitle, IconData icon, VoidCallback onAdd) {
    return Row(
      children: [
        Icon(icon, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        FilledButton.tonalIcon(
          onPressed: onAdd,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add'),
        ),
      ],
    );
  }
}
