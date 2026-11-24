import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/database/app_database.dart';
import '../../../core/storage/storage_location_service.dart';
import '../../../core/storage/portable_snapshot_events.dart';
import '../data/document_repository.dart';
import '../data/smart_collection_selection.dart';
import '../../categories/data/category_repository.dart';

class SmartCollectionsScreen extends StatefulWidget {
  const SmartCollectionsScreen({super.key});

  @override
  State<SmartCollectionsScreen> createState() => _SmartCollectionsScreenState();
}

class _SmartCollectionsScreenState extends State<SmartCollectionsScreen> {
  Future<Database> get _db => AppDatabase.instance.database;
  List<Map<String, Object?>> _collections = [];
  bool _loading = true;
  final _categoryRepository = CategoryRepository();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _ensureTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS smart_collections (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL COLLATE NOCASE UNIQUE,
        query_text TEXT NOT NULL DEFAULT '',
        favorites_only INTEGER NOT NULL DEFAULT 0,
        recent_only INTEGER NOT NULL DEFAULT 0,
        category_id TEXT,
        tag_ids_json TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    final columns = await db.rawQuery('PRAGMA table_info(smart_collections)');
    final names = columns.map((row) => row['name']).toSet();
    if (!names.contains('category_id')) await db.execute('ALTER TABLE smart_collections ADD COLUMN category_id TEXT');
    if (!names.contains('tag_ids_json')) await db.execute("ALTER TABLE smart_collections ADD COLUMN tag_ids_json TEXT NOT NULL DEFAULT '[]'");
    await db.execute('CREATE INDEX IF NOT EXISTS idx_smart_collections_name ON smart_collections(name COLLATE NOCASE)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_smart_collections_category ON smart_collections(category_id)');
  }

  Future<void> _load() async {
    try {
      final db = await _db;
      await _ensureTable(db);
      final rows = await db.query('smart_collections', orderBy: 'name COLLATE NOCASE');
      if (!mounted) return;
      setState(() { _collections = rows; _loading = false; });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load collections: $error')));
    }
  }

  List<String> _tagIds(Object? raw) {
    try {
      final decoded = jsonDecode(raw as String? ?? '[]');
      return decoded is List ? decoded.whereType<String>().toSet().toList() : const [];
    } catch (_) { return const []; }
  }

  Future<int> _count(Map<String, Object?> collection) async =>
      SmartCollectionSelection(collection).count(await _db);

  Future<List<Map<String, Object?>>> _candidates(Map<String, Object?> collection) async =>
      SmartCollectionSelection(collection).candidates(await _db);

  Future<void> _create() => _editCollection();

  Future<void> _edit(Map<String, Object?> item) => _editCollection(item);

  Future<void> _editCollection([Map<String, Object?>? item]) async {
    try {
      final categories = await _categoryRepository.listCategories();
      final tags = await _categoryRepository.listTags();
      if (!mounted) return;
      final draft = await showDialog<Map<String, Object?>>(
        context: context,
        builder: (_) => _SmartCollectionEditor(
          initial: item, categories: categories, tags: tags,
          repository: _categoryRepository, count: _count, candidates: _candidates,
        ),
      );
      if (draft == null || !mounted) return;
      final db = await _db;
      final duplicates = await db.query('smart_collections', columns: ['id'],
        where: item == null ? 'name = ? COLLATE NOCASE' :
            'name = ? COLLATE NOCASE AND id != ?',
        whereArgs: [draft['name'], if (item != null) item['id']], limit: 1);
      if (duplicates.isNotEmpty) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A Smart Collection with this name already exists.')));
        return;
      }
      final now = DateTime.now().toUtc().toIso8601String();
      if (item == null) {
        await db.insert('smart_collections', {
          ...draft, 'id': DateTime.now().microsecondsSinceEpoch.toString(),
          'created_at': now, 'updated_at': now,
        });
      } else {
        await db.update('smart_collections', {...draft, 'updated_at': now},
            where: 'id = ?', whereArgs: [item['id']]);
      }
      PortableSnapshotEvents.notifyDataChanged();
      await _load();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save collection: $error')));
    }
  }

  Future<void> _delete(Map<String, Object?> item) async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete collection?'),
      content: Text('“${item['name']}” will be removed. The PDFs themselves will not be changed.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
      ],
    ));
    if (ok != true) return;
    final db = await _db;
    await db.delete('smart_collections', where: 'id = ?', whereArgs: [item['id']]);
    PortableSnapshotEvents.notifyDataChanged();
    await _load();
  }

  Future<void> _open(Map<String, Object?> item) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _SmartCollectionResults(collection: item)));
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Smart Collections')),
    floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add), label: const Text('New collection')),
    body: _loading ? const Center(child: CircularProgressIndicator()) : _collections.isEmpty
      ? const Center(child: Padding(padding: EdgeInsets.all(28), child: Text('No Smart Collections yet. Use category, tags or manual selection. Only Grid PDFs are included; files stay in their original folders.')))
      : ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          itemCount: _collections.length,
          separatorBuilder: (_, _) => const SizedBox(height: 6),
          itemBuilder: (context, index) {
            final item = _collections[index];
            return FutureBuilder<int>(
              future: _count(item),
              builder: (context, snapshot) => Card(
                child: ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.auto_awesome_outlined)),
                  title: Text(item['name'] as String),
                  subtitle: Text([
                    if ((item['query_text'] as String).isNotEmpty || item['favorites_only'] == 1 || item['recent_only'] == 1) 'Legacy filter',
                    SmartCollectionSelection(item).mode == 'hybrid' ? 'Smart + Manual' : SmartCollectionSelection(item).mode == 'manual' ? 'Manual' : 'Automatic',
                    if ((item['category_id'] as String? ?? '').isNotEmpty) 'Category',
                    if (_tagIds(item['tag_ids_json']).isNotEmpty) '${_tagIds(item['tag_ids_json']).length} tags',
                    'Dynamic filter · no file copies',
                  ].join(' · ')),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(snapshot.hasData ? '${snapshot.data}' : '…'),
                    PopupMenuButton<String>(
                      onSelected: (value) {
                        if (value == 'edit') _edit(item);
                        if (value == 'delete') _delete(item);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ]),
                  onTap: () => _open(item),
                ),
              ),
            );
          },
        ),
  );
}

class _SmartCollectionResults extends StatefulWidget {
  const _SmartCollectionResults({required this.collection});
  final Map<String, Object?> collection;

  @override
  State<_SmartCollectionResults> createState() => _SmartCollectionResultsState();
}

class _SmartCollectionResultsState extends State<_SmartCollectionResults> {
  List<Map<String, Object?>> _rows = [];
  bool _loading = true;

  String? _error;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try {
      final rows = await SmartCollectionSelection(widget.collection)
          .results(await AppDatabase.instance.database);
      if (mounted) setState(() { _rows = rows; _loading = false; _error = null; });
    } catch (error) {
      if (mounted) setState(() { _loading = false; _error = error.toString(); });
    }
  }

  Future<void> _openPdf(Map<String, Object?> row) async {
    try {
      final document = await DocumentRepository().getById(row['id'] as String);
      if (!mounted || document == null || document.storagePath.isEmpty) return;
      await DocumentRepository().markOpened(document);
      await StorageLocationService.instance.openPdf(
        document.storagePath, gridPdf: true,
      );
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open PDF: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.collection['name'] as String)),
    body: _loading ? const Center(child: CircularProgressIndicator()) : _error != null
      ? Center(child: TextButton(onPressed: _load, child: const Text('Could not load PDFs. Retry')))
      : _rows.isEmpty
      ? const Center(child: Text('No PDFs match this collection right now.'))
      : ListView.separated(
          itemCount: _rows.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final row = _rows[index];
            final bytes = row['size_bytes'] as int? ?? 0;
            final size = bytes < 1024 * 1024 ? '${(bytes / 1024).toStringAsFixed(1)} KB' : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
            return ListTile(
              leading: Icon(row['is_favorite'] == 1 ? Icons.star : Icons.picture_as_pdf_outlined),
              title: Text('${row['name']}.pdf', maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(size),
              onTap: () => _openPdf(row),
            );
          },
        ),
  );
}

class _SmartCollectionEditor extends StatefulWidget {
  const _SmartCollectionEditor({
    required this.initial, required this.categories, required this.tags,
    required this.repository, required this.count, required this.candidates,
  });
  final Map<String, Object?>? initial;
  final List<CategoryRecord> categories;
  final List<TagRecord> tags;
  final CategoryRepository repository;
  final Future<int> Function(Map<String, Object?>) count;
  final Future<List<Map<String, Object?>>> Function(Map<String, Object?>) candidates;

  @override
  State<_SmartCollectionEditor> createState() => _SmartCollectionEditorState();
}

class _SmartCollectionEditorState extends State<_SmartCollectionEditor> {
  late final TextEditingController _name;
  late String _mode;
  late Set<String> _included;
  late Set<String> _excluded;
  bool _choosing = false;
  late List<TagRecord> _tags;
  late String _category;
  late Set<String> _selected;
  Timer? _debounce;
  int _generation = 0;
  int? _matching;
  bool _previewError = false;
  bool _creatingTag = false;
  bool _saving = false;

  bool get _legacy => widget.initial?['favorites_only'] == 1 ||
      widget.initial?['recent_only'] == 1 ||
      (widget.initial?['query_text'] as String? ?? '').isNotEmpty;
  bool get _hasRule => _category.isNotEmpty || _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final item = widget.initial;
    _name = TextEditingController(text: item?['name'] as String? ?? '');
    final previous = SmartCollectionSelection(item ?? {});
    _mode = previous.mode;
    _included = previous.included;
    _excluded = previous.excluded;
    _tags = [...widget.tags];
    final savedCategory = item?['category_id'] as String? ?? '';
    _category = widget.categories.any((c) => c.id == savedCategory) ? savedCategory : '';
    _selected = <String>{};
    try {
      final decoded = jsonDecode(item?['tag_ids_json'] as String? ?? '[]');
      if (decoded is List) {
        _selected.addAll(decoded.whereType<String>().where((id) => _tags.any((t) => t.id == id)));
      }
    } catch (_) {}
    _schedulePreview();
  }

  Map<String, Object?> _draft() => {
    'name': _name.text.trim(),
    'query_text': '',
    'selection_mode': _mode,
    'included_ids_json': jsonEncode(_mode == 'automatic' ? <String>[] : (_included.toList()..sort())),
    'excluded_ids_json': jsonEncode(_mode == 'hybrid' ? (_excluded.toList()..sort()) : <String>[]),
    'category_id': _category.isEmpty ? null : _category,
    'tag_ids_json': jsonEncode(_selected.toList()..sort()),
    'favorites_only': 0,
    'recent_only': 0,
  };

  void _schedulePreview() {
    _debounce?.cancel();
    final generation = ++_generation;
    final draft = _draft();
    setState(() { _matching = null; _previewError = false; });
    _debounce = Timer(const Duration(milliseconds: 200), () async {
      try {
        final count = await widget.count(draft);
        if (!mounted || generation != _generation) return;
        setState(() => _matching = count);
      } catch (_) {
        if (!mounted || generation != _generation) return;
        setState(() => _previewError = true);
      }
    });
  }

  Future<void> _addTag() async {
    if (_creatingTag) return;
    setState(() => _creatingTag = true);
    var value = '';
    try {
      final name = await showDialog<String>(context: context, builder: (ctx) =>
        AlertDialog(title: const Text('New tag'),
          content: TextField(autofocus: true, onChanged: (v) => value = v,
              decoration: const InputDecoration(labelText: 'Tag name')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, value.trim()), child: const Text('Create tag')),
          ],
        ));
      if (name == null || name.isEmpty || !mounted) return;
      final tag = await widget.repository.createTag(name);
      if (!mounted) return;
      setState(() {
        _tags.add(tag);
        _tags.sort((a,b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        _selected.add(tag.id);
      });
      _schedulePreview();
    } catch (error) {
      if (mounted) {
        await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
          title: const Text('Could not create tag'), content: Text(error.toString()),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ));
      }
    } finally {
      if (mounted) setState(() => _creatingTag = false);
    }
  }

  Future<void> _choosePdfs() async {
    if (_choosing) return;
    setState(() => _choosing = true);
    try {
      final rows = await widget.candidates(_draft());
      if (!mounted) return;
      final selected = SmartCollectionSelection(_draft());
      final chosen = await showDialog<Set<String>>(
        context: context,
        builder: (_) => _CollectionPdfPicker(
          rows: rows, initial: rows.where(selected.contains).map((r) => r['id'] as String).toSet(),
          manual: _mode == 'manual',
        ),
      );
      if (chosen == null || !mounted) return;
      if (_mode == 'manual') {
        _included = chosen;
        _excluded.clear();
      } else {
        // Keep overrides for currently absent/trashed PDFs; update only visible IDs.
        for (final row in rows) {
          final id = row['id'] as String;
          final match = row['rule_match'] == 1;
          if (chosen.contains(id)) {
            _excluded.remove(id);
            if (!match) _included.add(id);
          } else {
            _included.remove(id);
            if (match) _excluded.add(id);
          }
        }
      }
      _schedulePreview();
    } catch (error) {
      if (mounted) await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('Could not load Grid PDFs'), content: Text(error.toString()),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ));
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  Future<void> _save() async {
    if (_saving || _creatingTag || _choosing || _name.text.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      if (_mode == 'manual' && _included.isEmpty) {
        await _choosePdfs();
        if (_included.isEmpty || !mounted) return;
      }
      if (_mode != 'manual' && !_hasRule) {
        final confirmed = await showDialog<bool>(context: context, builder: (ctx) =>
          AlertDialog(title: const Text('No filter selected'),
            content: const Text('Without category or tag rules, all Grid PDFs match (except any manual exclusions). Save anyway?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep editing')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save all PDFs')),
            ],
          ));
        if (confirmed != true || !mounted) return;
      }
      if (mounted) Navigator.pop(context, _draft());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.initial == null ? 'New Smart Collection' : 'Edit Smart Collection'),
    content: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Grid PDFs only · files stay in their original folders'),
        const SizedBox(height: 12),
        TextField(controller: _name, autofocus: true,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(labelText: 'Collection name')),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: _mode, isExpanded: true,
          decoration: const InputDecoration(labelText: 'Selection mode'),
          items: const [
            DropdownMenuItem(value: 'automatic', child: Text('Automatic')),
            DropdownMenuItem(value: 'manual', child: Text('Manual')),
            DropdownMenuItem(value: 'hybrid', child: Text('Smart + Manual')),
          ],
          onChanged: (value) {
            _mode = value ?? 'automatic';
            _schedulePreview();
          },
        ),
        Text(_mode == 'manual' ? 'Choose fixed PDFs. Rules only help you find them.' :
          _mode == 'hybrid' ? 'New matches join automatically; your exceptions stay saved.' :
          'All current and future category/tag matches join automatically.'),

        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: _category, isExpanded: true,
          decoration: const InputDecoration(labelText: 'Category'),
          items: [
            const DropdownMenuItem(value: '', child: Text('Any category')),
            for (final category in widget.categories)
              DropdownMenuItem(value: category.id, child: Text(category.name)),
          ],
          onChanged: (value) {
            _category = value ?? '';
            _schedulePreview();
          },
        ),
        const SizedBox(height: 12),
        Row(children: [
          const Expanded(child: Text('Tags', style: TextStyle(fontWeight: FontWeight.w600))),
          TextButton.icon(onPressed: _creatingTag || _saving ? null : _addTag,
            icon: const Icon(Icons.add), label: const Text('New tag')),
        ]),
        if (_tags.isEmpty) const Text('No tags yet. Create a tag to use as a filter.'),
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (final tag in _tags) FilterChip(
            label: Text(tag.name), selected: _selected.contains(tag.id),
            onSelected: (selected) {
              if (selected) { _selected.add(tag.id); } else { _selected.remove(tag.id); }
              _schedulePreview();
            },
          ),
        ]),
        const SizedBox(height: 6),
        const Text('All selected tags must match. Assign tags to PDFs in Grid.'),
        const Divider(height: 24),
        if (_legacy) const Padding(padding: EdgeInsets.only(bottom: 8),
          child: Text('Saving changes removes this collection’s old name/starred/recent rules. Cancel to keep them.')),
        if (_mode != 'manual' && !_hasRule) const Padding(padding: EdgeInsets.only(bottom: 8),
          child: Text('No filter selected: all Grid PDFs will match.')),
        if (_previewError)
          TextButton(onPressed: _schedulePreview, child: const Text('Preview unavailable · Retry'))
        else if (_matching == null)
          const Text('Checking matching PDFs…')
        else
          Text('$_matching PDFs in collection', style: Theme.of(context).textTheme.titleMedium),
        if (_mode != 'automatic') OutlinedButton.icon(
          onPressed: _choosing || _saving ? null : _choosePdfs,
          icon: const Icon(Icons.checklist), label: const Text('Choose PDFs'),
        ),
      ],
    )),
    actions: [
      TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _saving || _creatingTag || _choosing || _name.text.trim().isEmpty ? null : _save,
        child: Text(widget.initial == null ? 'Save collection' : 'Save changes')),
    ],
  );
}


class _CollectionPdfPicker extends StatefulWidget {
  const _CollectionPdfPicker({required this.rows, required this.initial, required this.manual});
  final List<Map<String, Object?>> rows;
  final Set<String> initial;
  final bool manual;
  @override
  State<_CollectionPdfPicker> createState() => _CollectionPdfPickerState();
}

class _CollectionPdfPickerState extends State<_CollectionPdfPicker> {
  late final Set<String> _chosen = {...widget.initial};
  bool _matchesOnly = true;

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows.where((r) => !_matchesOnly ||
        r['rule_match'] == 1 || _chosen.contains(r['id'])).toList();
    final matches = widget.rows.where((r) => r['rule_match'] == 1).length;
    return AlertDialog(
      title: const Text('Choose Grid PDFs'),
      content: SizedBox(width: 480, height: 420, child: Column(children: [
        Text('$matches rule matches · ${_chosen.length} selected'),
        SwitchListTile(contentPadding: EdgeInsets.zero,
          title: const Text('Show matching PDFs only'), value: _matchesOnly,
          onChanged: (v) => setState(() => _matchesOnly = v)),
        Row(children: [
          TextButton(onPressed: () => setState(() => _chosen.addAll(rows.map((r) => r['id'] as String))),
              child: const Text('Select shown')),
          TextButton(onPressed: () => setState(() => _chosen.removeAll(rows.map((r) => r['id'] as String))),
              child: const Text('Clear shown')),
        ]),
        Expanded(child: ListView.builder(itemCount: rows.length, itemBuilder: (_, index) {
          final row = rows[index];
          final id = row['id'] as String;
          return CheckboxListTile(
            value: _chosen.contains(id),
            title: Text(row['name'] as String),
            subtitle: Text(row['rule_match'] == 1 ? 'Matches rule' : 'Outside rule'),
            onChanged: (v) => setState(() { if (v == true) { _chosen.add(id); } else { _chosen.remove(id); } }),
          );
        })),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _chosen), child: const Text('Done')),
      ],
    );
  }
}
