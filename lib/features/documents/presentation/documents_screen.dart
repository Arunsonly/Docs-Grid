import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import '../data/document_repository.dart';

class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key, this.favoritesOnly = false});
  final bool favoritesOnly;

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  final _repository = DocumentRepository();
  final _search = TextEditingController();
  List<DocumentRecord> _documents = [];
  bool _loading = true;
  bool _importing = false;
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
    try {
      final docs = await _repository.list(
        query: _search.text,
        favoritesOnly: widget.favoritesOnly,
      );
      if (!mounted) return;
      setState(() {
        _documents = docs;
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
    await OpenFilex.open(document.storagePath);
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

  Future<void> _trash(DocumentRecord document) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move to Recycle Bin?'),
        content: Text('${document.name}.pdf will be hidden from the library.'),
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
        subtitle: Text('${_size(document.sizeBytes)} · ${file.existsSync() ? 'On this device' : 'File missing'}'),
        trailing: PopupMenuButton<String>(
          onSelected: (value) async {
            if (value == 'favorite') {
              await _repository.setFavorite(document, !document.isFavorite);
              await _load();
            } else if (value == 'rename') {
              await _rename(document);
            } else if (value == 'trash') {
              await _trash(document);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'favorite',
              child: Text(document.isFavorite ? 'Remove from Saved' : 'Add to Saved')),
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
