import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/database/app_database.dart';
import '../../../core/storage/storage_location_service.dart';
import '../data/document_repository.dart';

class SmartCollectionsScreen extends StatefulWidget {
  const SmartCollectionsScreen({super.key});

  @override
  State<SmartCollectionsScreen> createState() => _SmartCollectionsScreenState();
}

class _SmartCollectionsScreenState extends State<SmartCollectionsScreen> {
  Future<Database> get _db => AppDatabase.instance.database;
  List<Map<String, Object?>> _collections = [];
  bool _loading = true;

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
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_smart_collections_name ON smart_collections(name COLLATE NOCASE)');
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

  Future<int> _count(Map<String, Object?> collection) async {
    final db = await _db;
    final where = <String>['deleted_at IS NULL'];
    final args = <Object?>[];
    if (collection['favorites_only'] == 1) where.add('is_favorite = 1');
    if (collection['recent_only'] == 1) where.add('last_opened_at IS NOT NULL');
    final query = (collection['query_text'] as String? ?? '').trim();
    if (query.isNotEmpty) {
      where.add("name LIKE ? ESCAPE '\\'");
      args.add('%${query.replaceAll('\\', '\\\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%');
    }
    final rows = await db.rawQuery('SELECT COUNT(*) AS total FROM documents WHERE ${where.join(' AND ')}', args);
    return (rows.first['total'] as int?) ?? 0;
  }

  Future<void> _create() async {
    final name = TextEditingController();
    final query = TextEditingController();
    var starred = false;
    var recent = false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: const Text('New Smart Collection'),
          content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Collection name')),
            TextField(controller: query, decoration: const InputDecoration(labelText: 'PDF name contains (optional)')),
            CheckboxListTile(contentPadding: EdgeInsets.zero, value: starred, title: const Text('Starred PDFs only'), onChanged: (v) => refresh(() => starred = v ?? false)),
            CheckboxListTile(contentPadding: EdgeInsets.zero, value: recent, title: const Text('Recently opened only'), onChanged: (v) => refresh(() => recent = v ?? false)),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Save collection')),
          ],
        ),
      ),
    );
    if (saved != true) { name.dispose(); query.dispose(); return; }
    final label = name.text.trim();
    if (label.isEmpty) {
      name.dispose(); query.dispose();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a collection name.')));
      return;
    }
    try {
      final db = await _db;
      await _ensureTable(db);
      final now = DateTime.now().toUtc().toIso8601String();
      await db.insert('smart_collections', {
        'id': '${DateTime.now().microsecondsSinceEpoch}',
        'name': label,
        'query_text': query.text.trim(),
        'favorites_only': starred ? 1 : 0,
        'recent_only': recent ? 1 : 0,
        'created_at': now,
        'updated_at': now,
      });
      await _load();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save collection: $error')));
    } finally {
      name.dispose(); query.dispose();
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
    await _load();
  }

  Future<void> _open(Map<String, Object?> item) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => _SmartCollectionResults(collection: item)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Smart Collections')),
    floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add), label: const Text('New collection')),
    body: _loading ? const Center(child: CircularProgressIndicator()) : _collections.isEmpty
      ? const Center(child: Padding(padding: EdgeInsets.all(28), child: Text('No Smart Collections yet. Create a saved filter for starred, recent, or name-matched PDFs. Your files stay in their original folders.')))
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
                    if ((item['query_text'] as String).isNotEmpty) 'Name: ${item['query_text']}',
                    if (item['favorites_only'] == 1) 'Starred',
                    if (item['recent_only'] == 1) 'Recent',
                    'Dynamic filter · no file copies',
                  ].join(' · ')),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(snapshot.hasData ? '${snapshot.data}' : '…'),
                    PopupMenuButton<String>(onSelected: (v) { if (v == 'delete') _delete(item); }, itemBuilder: (_) => const [PopupMenuItem(value: 'delete', child: Text('Delete'))]),
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

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final db = await AppDatabase.instance.database;
    final where = <String>['d.deleted_at IS NULL'];
    final args = <Object?>[];
    if (widget.collection['favorites_only'] == 1) where.add('d.is_favorite = 1');
    if (widget.collection['recent_only'] == 1) where.add('d.last_opened_at IS NOT NULL');
    final query = (widget.collection['query_text'] as String? ?? '').trim();
    if (query.isNotEmpty) {
      where.add("d.name LIKE ? ESCAPE '\\'");
      args.add('%${query.replaceAll('\\', '\\\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%');
    }
    final rows = await db.rawQuery('SELECT d.id, d.name, d.storage_uri, d.size_bytes, d.is_favorite, d.last_opened_at FROM documents d WHERE ${where.join(' AND ')} ORDER BY d.last_opened_at DESC, d.name COLLATE NOCASE', args);
    if (!mounted) return;
    setState(() { _rows = rows; _loading = false; });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.collection['name'] as String)),
    body: _loading ? const Center(child: CircularProgressIndicator()) : _rows.isEmpty
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
            );
          },
        ),
  );
}