import 'package:flutter/material.dart';

class PhoneStorageBrowserScreen extends StatefulWidget {
  const PhoneStorageBrowserScreen({
    super.key,
    required this.rootName,
    required this.entries,
    required this.onOpenPdf,
    this.onMovePdf,
    this.onRenamePdf,
    this.onSharePdf,
    this.onTrashPdf,
    this.initialPath = '',
  });

  final String rootName;
  final List<Map<String, Object?>> entries;
  final Future<void> Function(String uri, String name) onOpenPdf;
  final Future<bool> Function(String uri, String name)? onMovePdf;
  final Future<bool> Function(String uri, String name)? onRenamePdf;
  final Future<void> Function(String uri, String name)? onSharePdf;
  final Future<bool> Function(String uri, String name)? onTrashPdf;
  final String initialPath;

  @override
  State<PhoneStorageBrowserScreen> createState() =>
      _PhoneStorageBrowserScreenState();
}

class _PhoneStorageBrowserScreenState extends State<PhoneStorageBrowserScreen> {
  String? _selectedFolderPath;

  String _normalizePath(String value) {
    final separator = String.fromCharCode(92);
    return value
        .trim()
        .replaceAll(separator, '/')
        .replaceAll(RegExp(r'/+'), '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
  }

  String _normalizedFolderPath(Map<String, Object?> entry) {
    // Some storage providers include folderPath as an empty string even when
    // path contains the actual parent directory. Treat blank as missing.
    final folderPath = entry['folderPath'];
    final path = entry['path'];
    final rawValue = folderPath is String && folderPath.trim().isNotEmpty
        ? folderPath
        : path ?? folderPath ?? '';
    if (rawValue is! String) return '';
    final raw = _normalizePath(rawValue);
    final root = _normalizePath(widget.rootName);
    if (raw.toLowerCase() == root.toLowerCase()) return '';
    if (raw.length > root.length &&
        raw.substring(0, root.length).toLowerCase() == root.toLowerCase() &&
        raw[root.length] == '/') {
      return raw.substring(root.length + 1);
    }
    return raw;
  }

  bool _isPdfFile(Map<String, Object?> entry) {
    if (entry['isDirectory'] == true ||
        entry['isInaccessible'] == true ||
        entry['isInaccessibleSummary'] == true) {
      return false;
    }
    final name = entry['name'];
    final uri = entry['uri'];
    return name is String &&
        name.trim().toLowerCase().endsWith('.pdf') &&
        uri is String &&
        uri.trim().isNotEmpty;
  }

  List<Map<String, Object?>> get _pdfs =>
      widget.entries.where(_isPdfFile).toList(growable: false);

  Map<String, List<Map<String, Object?>>> get _directPdfFolders {
    final grouped = <String, List<Map<String, Object?>>>{};
    for (final pdf in _pdfs) {
      final path = _normalizedFolderPath(pdf);
      // PDFs located directly in the storage root are not folders.
      if (path.isEmpty) continue;
      (grouped[path] ??= <Map<String, Object?>>[]).add(pdf);
    }
    final sorted = grouped.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return {
      for (final path in sorted)
        path: grouped[path]!
          ..sort((a, b) => (a['name'] as String)
              .toLowerCase()
              .compareTo((b['name'] as String).toLowerCase())),
    };
  }

  String _folderName(String path) => path.split('/').last;

  String _displayPath(String path) =>
      path.startsWith('/') ? path : '${widget.rootName}/$path';

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _runPdfAction(
    String action,
    Map<String, Object?> entry,
  ) async {
    final uri = entry['uri'] as String;
    final name = entry['name'] as String;
    var sourceChanged = false;
    if (action == 'move') {
      sourceChanged = await widget.onMovePdf?.call(uri, name) ?? false;
    } else if (action == 'rename') {
      sourceChanged = await widget.onRenamePdf?.call(uri, name) ?? false;
    } else if (action == 'share') {
      await widget.onSharePdf?.call(uri, name);
    } else if (action == 'trash') {
      sourceChanged = await widget.onTrashPdf?.call(uri, name) ?? false;
    }
    if (sourceChanged && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final folders = _directPdfFolders;
    final selectedPath = _selectedFolderPath;
    final selectedFiles = selectedPath == null
        ? const <Map<String, Object?>>[]
        : folders[selectedPath] ?? const [];

    return Scaffold(
      appBar: AppBar(
        leading: selectedPath == null
            ? null
            : IconButton(
                tooltip: 'Back to folders',
                onPressed: () => setState(() => _selectedFolderPath = null),
                icon: const Icon(Icons.arrow_back),
              ),
        title: Text(
          selectedPath == null ? widget.rootName : _folderName(selectedPath),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: selectedPath == null
          ? folders.isEmpty
              ? const Center(child: Text('No folders with direct PDF files.'))
              : ListView.builder(
                  itemCount: folders.length,
                  itemBuilder: (context, index) {
                    final path = folders.keys.elementAt(index);
                    final files = folders[path]!;
                    final bytes = files.fold<int>(
                      0,
                      (sum, file) =>
                          sum + ((file['sizeBytes'] as num?)?.toInt() ?? 0),
                    );
                    return ListTile(
                      key: ValueKey('phone-folder-$path'),
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(
                        _folderName(path),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${files.length} PDFs · ${_formatSize(bytes)}',
                      ),
                      onTap: () =>
                          setState(() => _selectedFolderPath = path),
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Folder details and actions',
                        onSelected: (value) {
                          if (value == 'open') {
                            setState(() => _selectedFolderPath = path);
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem<String>(
                            enabled: false,
                            child: SizedBox(
                              width: 240,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _folderName(path),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _displayPath(path),
                                    style: Theme.of(context).textTheme.bodySmall,
                                    softWrap: true,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const PopupMenuDivider(),
                          const PopupMenuItem(
                            value: 'open',
                            child: Text('Open folder'),
                          ),
                        ],
                      ),
                    );
                  },
                )
          : selectedFiles.isEmpty
              ? const Center(child: Text('No PDF files in this folder.'))
              : ListView.builder(
                  itemCount: selectedFiles.length,
                  itemBuilder: (context, index) {
                    final entry = selectedFiles[index];
                    return ListTile(
                      leading: const Icon(Icons.picture_as_pdf_outlined),
                      title: Text(
                        entry['name'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: const Text('PDF document'),
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) => _runPdfAction(action, entry),
                        itemBuilder: (_) => [
                          if (widget.onMovePdf != null)
                            const PopupMenuItem(value: 'move', child: Text('Move to Grid')),
                          if (widget.onRenamePdf != null)
                            const PopupMenuItem(value: 'rename', child: Text('Rename')),
                          if (widget.onSharePdf != null)
                            const PopupMenuItem(value: 'share', child: Text('Share')),
                          if (widget.onTrashPdf != null)
                            const PopupMenuItem(value: 'trash', child: Text('Move to Recycle Bin')),
                        ],
                      ),
                      onTap: () => widget.onOpenPdf(
                        entry['uri'] as String,
                        entry['name'] as String,
                      ),
                    );
                  },
                ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            heightFactor: 1,
            child: Text(
              selectedPath == null
                  ? '${folders.length} folders'
                  : '${selectedFiles.length} PDFs',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ),
    );
  }
}
