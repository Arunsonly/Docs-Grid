import 'package:flutter/material.dart';
import '../data/document_repository.dart';

/// UI-only selection. Actual deletions use the existing durable repositories.
class RecycleBinDialog extends StatefulWidget {
  const RecycleBinDialog({
    super.key,
    required this.folders,
    required this.pdfs,
    required this.inspectFolder,
    required this.restoreFolder,
    required this.deleteFolder,
    required this.restorePdf,
    required this.deletePdf,
    required this.onChanged,
  });
  final List<Map<String, Object?>> folders;
  final List<DocumentRecord> pdfs;
  final Future<Map<String, Object?>> Function(String) inspectFolder;
  final Future<void> Function(String) restoreFolder;
  final Future<void> Function(String) deleteFolder;
  final Future<void> Function(DocumentRecord) restorePdf;
  final Future<void> Function(DocumentRecord) deletePdf;
  final Future<void> Function({required bool pdfChanged}) onChanged;

  @override
  State<RecycleBinDialog> createState() => _RecycleBinDialogState();
}

class _RecycleBinDialogState extends State<RecycleBinDialog> {
  late final List<Map<String, Object?>> _folders = [...widget.folders];
  late final List<DocumentRecord> _pdfs = [...widget.pdfs];
  final Set<String> _selectedFolders = {};
  final Set<String> _selectedPdfs = {};
  bool _selecting = false;
  bool _busy = false;

  int get _count => _selectedFolders.length + _selectedPdfs.length;
  int get _total => _folders.length + _pdfs.length;
  bool get _allSelected => _total > 0 && _count == _total;

  void _clearSelection() {
    if (_busy || !mounted) return;
    setState(() {
      _selecting = false;
      _selectedFolders.clear();
      _selectedPdfs.clear();
    });
  }

  void _toggle(String id, {required bool folder}) {
    if (_busy) return;
    setState(() {
      _selecting = true;
      final selected = folder ? _selectedFolders : _selectedPdfs;
      if (!selected.add(id)) selected.remove(id);
    });
  }

  void _toggleAll() {
    if (_busy) return;
    setState(() {
      if (_allSelected) {
        _selectedFolders.clear();
        _selectedPdfs.clear();
      } else {
        _selectedFolders
          ..clear()
          ..addAll(_folders.map((item) => item['id'] as String));
        _selectedPdfs
          ..clear()
          ..addAll(_pdfs.map((item) => item.id));
      }
    });
  }

  Future<void> _error(String title, Object error) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text('$error'),
        actions: [TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        )],
      ),
    );
  }

  Future<bool> _confirmDelete(int folders, int pdfs) async {
    if (!mounted || folders + pdfs == 0) return false;
    return await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete permanently?'),
        content: Text(
          'Delete $folders folder(s) and $pdfs PDF(s) permanently? '
          'PDFs inside selected folders are included. '
          'This cannot be undone. Untracked items remain protected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    ) == true;
  }

  Future<void> _inspect(String id) async {
    try {
      final data = await widget.inspectFolder(id);
      if (!mounted) return;
      final folders = (data['folders'] as List).cast<Map<String, Object?>>();
      final pdfs = (data['documents'] as List).cast<Map<String, Object?>>();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(data['rootName'] as String? ?? 'Deleted folder'),
          content: SizedBox(
            width: double.maxFinite,
            height: 360,
            child: ListView(children: [
              const Text('FOLDERS', style: TextStyle(fontWeight: FontWeight.w700)),
              for (final folder in folders) ListTile(
                dense: true,
                leading: const Icon(Icons.folder_outlined),
                title: Text(folder['path'] as String? ?? ''),
              ),
              const Divider(),
              const Text('PDF FILES', style: TextStyle(fontWeight: FontWeight.w700)),
              for (final pdf in pdfs) ListTile(
                dense: true,
                leading: const Icon(Icons.picture_as_pdf_outlined),
                title: Text(pdf['name'] as String? ?? 'PDF'),
                subtitle: Text('${pdf['size_bytes'] ?? 0} bytes'),
              ),
            ]),
          ),
          actions: [TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          )],
        ),
      );
    } catch (e) {
      await _error('Could not inspect deleted folder', e);
    }
  }

  Future<void> _refresh({required bool pdfChanged}) async {
    try {
      await widget.onChanged(pdfChanged: pdfChanged);
    } catch (e) {
      await _error('Recycle Bin refresh failed', e);
    }
  }

  Future<void> _singleFolder(String id, String action) async {
    if (_busy) return;
    if (action == 'delete' && !await _confirmDelete(1, 0)) return;
    if (!mounted) return;
    setState(() => _busy = true);
    var succeeded = false;
    try {
      if (action == 'restore') {
        await widget.restoreFolder(id);
      } else {
        await widget.deleteFolder(id);
      }
      succeeded = true;
      if (mounted) setState(() {
        _folders.removeWhere((item) => item['id'] == id);
        _selectedFolders.remove(id);
      });
    } catch (e) {
      await _error('Folder Recycle Bin action failed', e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (succeeded && mounted) await _refresh(pdfChanged: false);
  }

  Future<void> _singlePdf(DocumentRecord pdf, String action) async {
    if (_busy) return;
    if (action == 'delete' && !await _confirmDelete(0, 1)) return;
    if (!mounted) return;
    setState(() => _busy = true);
    var succeeded = false;
    try {
      if (action == 'restore') {
        await widget.restorePdf(pdf);
      } else {
        await widget.deletePdf(pdf);
      }
      succeeded = true;
      if (mounted) setState(() {
        _pdfs.removeWhere((item) => item.id == pdf.id);
        _selectedPdfs.remove(pdf.id);
      });
    } catch (e) {
      await _error('PDF Recycle Bin action failed', e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (succeeded && mounted) await _refresh(pdfChanged: true);
  }

  Future<void> _deleteSelected() async {
    if (_busy || _count == 0) return;
    final folders = _folders.where(
        (item) => _selectedFolders.contains(item['id'])).toList();
    final pdfs = _pdfs.where(
        (item) => _selectedPdfs.contains(item.id)).toList();
    if (!await _confirmDelete(folders.length, pdfs.length) || !mounted) return;
    setState(() => _busy = true);
    final failures = <String>[];
    var deleted = false;
    var pdfChanged = false;
    // Keep independent operations isolated: a failed item stays selected and
    // cannot hide a successful item or trigger an unintended restore.
    for (final folder in folders) {
      final id = folder['id'] as String;
      try {
        await widget.deleteFolder(id);
        deleted = true;
        if (!mounted) return;
        setState(() {
          _folders.removeWhere((item) => item['id'] == id);
          _selectedFolders.remove(id);
        });
      } catch (e) {
        failures.add('${folder['name'] ?? 'Folder'}: $e');
      }
    }
    for (final pdf in pdfs) {
      try {
        await widget.deletePdf(pdf);
        deleted = true;
        pdfChanged = true;
        if (!mounted) return;
        setState(() {
          _pdfs.removeWhere((item) => item.id == pdf.id);
          _selectedPdfs.remove(pdf.id);
        });
      } catch (e) {
        failures.add('${pdf.name}.pdf: $e');
      }
    }
    if (mounted) setState(() {
      _busy = false;
      if (failures.isEmpty) {
        _selecting = false;
        _selectedFolders.clear();
        _selectedPdfs.clear();
      }
    });
    if (deleted && mounted) await _refresh(pdfChanged: pdfChanged);
    if (failures.isNotEmpty && mounted) {
      await _error('Some items could not be deleted',
          'Failed items remain selected. Check them before retrying: '
          '${failures.take(3).join('; ')}');
    }
  }

  Widget _folderTile(Map<String, Object?> folder) {
    final id = folder['id'] as String;
    final selected = _selectedFolders.contains(id);
    return ListTile(
      key: ValueKey('recycle-folder-$id'),
      contentPadding: EdgeInsets.zero,
      leading: _selecting
          ? Checkbox(
              key: ValueKey('recycle-folder-check-$id'),
              value: selected,
              onChanged: _busy ? null : (_) => _toggle(id, folder: true),
            )
          : const Icon(Icons.folder_outlined),
      title: Text(folder['name'] as String? ?? 'Folder',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${folder['folder_count'] ?? 1} folders · '
        '${folder['pdf_count'] ?? 0} PDFs · '
        'Deleted ${folder['deleted_at'] ?? ''}',
        maxLines: 2, overflow: TextOverflow.ellipsis,
      ),
      selected: _selecting && selected,
      onLongPress: _busy || _selecting ? null :
          () => _toggle(id, folder: true),
      onTap: _busy ? null :
          () => _selecting ? _toggle(id, folder: true) : _inspect(id),
      trailing: _selecting ? null : PopupMenuButton<String>(
        key: ValueKey('recycle-folder-menu-$id'),
        enabled: !_busy,
        onSelected: (action) => _singleFolder(id, action),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'restore', child: Text('Restore folder')),
          PopupMenuItem(value: 'delete', child: Text('Delete permanently')),
        ],
      ),
    );
  }

  Widget _pdfTile(DocumentRecord pdf) {
    final selected = _selectedPdfs.contains(pdf.id);
    return ListTile(
      key: ValueKey('recycle-pdf-${pdf.id}'),
      contentPadding: EdgeInsets.zero,
      leading: _selecting
          ? Checkbox(
              key: ValueKey('recycle-pdf-check-${pdf.id}'),
              value: selected,
              onChanged: _busy ? null : (_) => _toggle(pdf.id, folder: false),
            )
          : const Icon(Icons.picture_as_pdf_outlined),
      title: Text('${pdf.name}.pdf', maxLines: 1,
          overflow: TextOverflow.ellipsis),
      subtitle: const Text('PDF moved to Recycle Bin'),
      selected: _selecting && selected,
      onLongPress: _busy || _selecting ? null :
          () => _toggle(pdf.id, folder: false),
      onTap: _busy || !_selecting ? null :
          () => _toggle(pdf.id, folder: false),
      trailing: _selecting ? null : PopupMenuButton<String>(
        key: ValueKey('recycle-pdf-menu-${pdf.id}'),
        enabled: !_busy,
        onSelected: (action) => _singlePdf(pdf, action),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'restore', child: Text('Restore')),
          PopupMenuItem(value: 'delete', child: Text('Delete permanently')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    // Back exits selection; only the following Back closes Recycle Bin.
    canPop: !_selecting && !_busy,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && _selecting && !_busy) _clearSelection();
    },
    child: AlertDialog(
      title: const Text('Recycle Bin'),
      content: SizedBox(
        width: double.maxFinite,
        height: 420,
        child: Column(children: [
          if (_selecting)
            Row(children: [
              Expanded(child: Text('$_count selected',
                  key: const ValueKey('recycle-selected-count'),
                  style: const TextStyle(fontWeight: FontWeight.w600))),
              TextButton(
                key: const ValueKey('recycle-select-all'),
                onPressed: _busy ? null : _toggleAll,
                child: Text(_allSelected ? 'Deselect All' : 'Select All'),
              ),
            ]),
          Expanded(child: _folders.isEmpty && _pdfs.isEmpty
              ? const Center(child: Text('Recycle Bin is empty.'))
              : ListView(
                  key: const ValueKey('recycle-bin-list'),
                  children: [
                    if (_folders.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.only(top: 4, bottom: 6),
                        child: Text('FOLDERS',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      for (final folder in _folders) _folderTile(folder),
                    ],
                    if (_pdfs.isNotEmpty) ...[
                      if (_folders.isNotEmpty) const Divider(),
                      const Padding(
                        padding: EdgeInsets.only(top: 4, bottom: 6),
                        child: Text('PDF FILES',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      for (final pdf in _pdfs) _pdfTile(pdf),
                    ],
                  ],
                )),
          if (_selecting)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const ValueKey('recycle-delete-selected'),
                  onPressed: _busy || _count == 0 ? null : _deleteSelected,
                  icon: const Icon(Icons.delete_outline),
                  label: Text('Delete Selected ($_count)'),
                ),
              ),
            ),
        ]),
      ),
      actions: [
        TextButton(
          key: const ValueKey('recycle-close'),
          onPressed: _busy ? null : _selecting
              ? _clearSelection : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
