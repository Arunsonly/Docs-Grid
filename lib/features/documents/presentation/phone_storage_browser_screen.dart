import 'package:flutter/material.dart';

import 'document_thumbnail.dart';

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
    this.embedded = false,
    this.isLoading = false,
    this.onRefresh,
  });

  final String rootName;
  final List<Map<String, Object?>> entries;
  final Future<void> Function(String uri, String name) onOpenPdf;
  final Future<bool> Function(String uri, String name)? onMovePdf;
  final Future<bool> Function(String uri, String name)? onRenamePdf;
  final Future<void> Function(String uri, String name)? onSharePdf;
  final Future<bool> Function(String uri, String name)? onTrashPdf;
  final String initialPath;
  final bool embedded;
  final bool isLoading;
  final Future<void> Function()? onRefresh;

  @override
  State<PhoneStorageBrowserScreen> createState() =>
      _PhoneStorageBrowserScreenState();
}

class _PhoneStorageBrowserScreenState extends State<PhoneStorageBrowserScreen> {
  String? _selectedFolderPath;
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _selectedFolderPath =
        widget.initialPath.isEmpty ? null : _normalizePath(widget.initialPath);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _normalizePath(String value) {
    final separator = String.fromCharCode(92);
    return value
        .trim()
        .replaceAll(separator, '/')
        .replaceAll(RegExp(r'/+'), '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
  }

  String _rootRelativePath(String value) {
    final raw = _normalizePath(value);
    final root = _normalizePath(widget.rootName);
    if (raw.toLowerCase() == root.toLowerCase()) return '';
    if (raw.length > root.length &&
        raw.substring(0, root.length).toLowerCase() == root.toLowerCase() &&
        raw[root.length] == '/') {
      return raw.substring(root.length + 1);
    }

    // Scanner root label and visible screen title are intentionally different.
    const internalRoot = 'Internal';
    if (raw.toLowerCase() == internalRoot.toLowerCase()) return '';
    if (raw.length > internalRoot.length &&
        raw.substring(0, internalRoot.length).toLowerCase() ==
            internalRoot.toLowerCase() &&
        raw[internalRoot.length] == '/') {
      return raw.substring(internalRoot.length + 1);
    }
    return raw;
  }

  String _normalizedFolderPath(Map<String, Object?> entry) {
    final folderPath = entry['folderPath'];
    final path = entry['path'];
    final rawValue = folderPath is String && folderPath.trim().isNotEmpty
        ? folderPath
        : path ?? folderPath ?? '';
    if (rawValue is! String) return '';
    return _rootRelativePath(rawValue);
  }

  String _normalizedDirectoryPath(Map<String, Object?> entry) {
    final rawValue = entry['path'];
    if (rawValue is! String) return '';
    return _rootRelativePath(rawValue);
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
      final rawPath = _normalizedFolderPath(pdf);
      // Files directly under the storage root belong in a virtual Internal
      // folder instead of being silently omitted.
      final path = rawPath.isEmpty ? 'Internal' : rawPath;
      (grouped[path] ??= <Map<String, Object?>>[]).add(pdf);
    }
    for (final entry in widget.entries) {
      if (entry['isDirectory'] != true ||
          entry['isInaccessible'] == true ||
          entry['isInaccessibleSummary'] == true) {
        continue;
      }
      final path = _normalizedDirectoryPath(entry);
      if (path.isEmpty) continue;
      final count = (entry['pdfCount'] as num?)?.toInt() ?? 0;
      if (count > 0 || entry['isPending'] == true) {
        grouped.putIfAbsent(path, () => <Map<String, Object?>>[]);
      }
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

  Map<String, Object?>? _directoryFor(String path) {
    for (final entry in widget.entries) {
      if (entry['isDirectory'] == true &&
          _normalizedDirectoryPath(entry) == path) {
        return entry;
      }
    }
    return null;
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

  String _formatModifiedAt(Object? rawValue) {
    DateTime? value;
    if (rawValue is num && rawValue > 0) {
      value = DateTime.fromMillisecondsSinceEpoch(rawValue.toInt()).toLocal();
    } else if (rawValue is String && rawValue.trim().isNotEmpty) {
      value = DateTime.tryParse(rawValue)?.toLocal();
    } else if (rawValue is DateTime) {
      value = rawValue.toLocal();
    }
    if (value == null) return 'Date unavailable';
    const months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final day = value.day.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$day-${months[value.month - 1]}-${value.year} $hour:$minute';
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
    if (!sourceChanged || !mounted) return;
    if (widget.embedded) {
      setState(() => _selectedFolderPath = null);
      await widget.onRefresh?.call();
    } else {
      Navigator.of(context).pop();
    }
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: TextField(
        controller: _searchController,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: 'Search phone folders or PDF names',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  onPressed: () {
                    _searchController.clear();
                    setState(() {});
                  },
                  icon: const Icon(Icons.close),
                ),
          filled: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildFolderTile(String path, List<Map<String, Object?>> files) {
    final directory = _directoryFor(path);
    final bytes = (directory?['sizeBytes'] as num?)?.toInt() ??
        files.fold<int>(
          0,
          (sum, file) => sum + ((file['sizeBytes'] as num?)?.toInt() ?? 0),
        );
    final count = (directory?['pdfCount'] as num?)?.toInt() ?? files.length;
    return ListTile(
      key: ValueKey('phone-folder-$path'),
      leading: const Icon(Icons.folder_outlined),
      title: Text(
        _folderName(path),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text('$count PDFs · ${_formatSize(bytes)}'),
      onTap: () => setState(() => _selectedFolderPath = path),
      trailing: PopupMenuButton<String>(
        tooltip: 'Folder details and actions',
        onSelected: (value) {
          if (value == 'open') setState(() => _selectedFolderPath = path);
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
                  Text(_folderName(path),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
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
          const PopupMenuItem(value: 'open', child: Text('Open folder')),
        ],
      ),
    );
  }

  Widget _buildPdfTile(
    Map<String, Object?> entry, {
    String? locationLabel,
  }) {
    final uri = entry['uri'] as String;
    final sizeBytes = (entry['sizeBytes'] as num?)?.toInt() ??
        (entry['size'] as num?)?.toInt() ?? 0;
    final details = <String>[
      _formatModifiedAt(entry['lastModified']),
      _formatSize(sizeBytes),
      if (locationLabel != null && locationLabel.isNotEmpty) locationLabel,
    ].join(' · ');
    return ListTile(
      leading: DocumentThumbnail(
        key: ValueKey('phone-thumbnail-$uri'),
        documentId: 'phone_$uri',
        storagePath: uri,
        sizeBytes: sizeBytes,
      ),
      title: Text(
        entry['name'] as String,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
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
            const PopupMenuItem(
              value: 'trash',
              child: Text('Move to Recycle Bin'),
            ),
        ],
      ),
      onTap: () => widget.onOpenPdf(
        entry['uri'] as String,
        entry['name'] as String,
      ),
    );
  }

  Widget _buildBrowserContent() {
    final folders = _directPdfFolders;
    final selectedPath = _selectedFolderPath;
    final selectedFiles = selectedPath == null
        ? const <Map<String, Object?>>[]
        : folders[selectedPath] ?? const <Map<String, Object?>>[];
    final query = _searchController.text.trim().toLowerCase();
    final folderPaths = folders.keys
        .where((path) =>
            selectedPath != null || query.isEmpty || path.toLowerCase().contains(query))
        .toList(growable: false);
    final matchingPdfs = _pdfs.where((entry) {
      final name = (entry['name'] as String).toLowerCase();
      final folderPath = _normalizedFolderPath(entry).toLowerCase();
      final matchesQuery =
          query.isEmpty || name.contains(query) || folderPath.contains(query);
      return matchesQuery &&
          (selectedPath == null ||
              (folderPath.isEmpty ? 'Internal' : folderPath) == selectedPath);
    }).toList(growable: false);

    final isSearching = query.isNotEmpty;
    var visiblePdfCount = matchingPdfs.length;
    final children = <Widget>[];
    if (selectedPath == null) {
      if (folderPaths.isNotEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('FOLDERS',
                style: Theme.of(context).textTheme.labelLarge),
          ),
        );
        for (final path in folderPaths) {
          children.add(_buildFolderTile(path, folders[path]!));
        }
      }
      if (isSearching && matchingPdfs.isNotEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('PDF FILES',
                style: Theme.of(context).textTheme.labelLarge),
          ),
        );
        for (final entry in matchingPdfs) {
          final path = _normalizedFolderPath(entry);
          children.add(_buildPdfTile(
            entry,
            locationLabel: path.isEmpty ? 'Internal' : _displayPath(path),
          ));
        }
      }
      if (children.isEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isSearching
                      ? 'No matching folders or PDFs.'
                      : widget.isLoading
                          ? 'Reading Phone storage…'
                          : 'No PDF folders found. Pull down to refresh.',
                  textAlign: TextAlign.center,
                ),
                if (!widget.isLoading && widget.entries.isEmpty &&
                    widget.onRefresh != null) ...[
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: widget.onRefresh,
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text('Open Phone storage'),
                  ),
                ],
              ],
            ),
          ),
        );
      }
    } else {
      final visibleFiles = isSearching
          ? selectedFiles.where((entry) {
              final name = (entry['name'] as String).toLowerCase();
              return name.contains(query);
            }).toList(growable: false)
          : selectedFiles;
      visiblePdfCount = visibleFiles.length;
      if (visibleFiles.isEmpty) {
        children.add(
          Padding(
            padding: const EdgeInsets.all(28),
            child: Center(
              child: Text(
                widget.isLoading
                    ? 'Scanning this folder…'
                    : isSearching
                        ? 'No matching PDFs in this folder.'
                        : 'No PDF files in this folder.',
              ),
            ),
          ),
        );
      } else {
        for (final entry in visibleFiles) {
          children.add(_buildPdfTile(entry));
        }
      }
    }

    return Column(
      children: [
        if (widget.embedded && selectedPath != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back to folders',
                  onPressed: () => setState(() => _selectedFolderPath = null),
                  icon: const Icon(Icons.arrow_back),
                ),
                Expanded(
                  child: Text(
                    _folderName(selectedPath),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
          ),
        _buildSearchField(),
        if (widget.isLoading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: RefreshIndicator(
            onRefresh: widget.onRefresh ?? () async {},
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: children,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              selectedPath == null
                  ? '${folderPaths.length} folders · ${matchingPdfs.length} PDFs'
                  : '$visiblePdfCount PDFs',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedPath = _selectedFolderPath;
    if (widget.embedded) {
      return PopScope<void>(
        canPop: selectedPath == null,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && _selectedFolderPath != null && mounted) {
            setState(() => _selectedFolderPath = null);
          }
        },
        child: _buildBrowserContent(),
      );
    }

    return PopScope<void>(
      canPop: selectedPath == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _selectedFolderPath != null && mounted) {
          setState(() => _selectedFolderPath = null);
        }
      },
      child: Scaffold(
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
        actions: [
          IconButton(
            tooltip: 'Refresh Phone storage',
            onPressed: widget.onRefresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBrowserContent(),
      ),
    );
  }
}
