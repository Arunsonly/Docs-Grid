import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/widgets/storage_sort_controls.dart';
import '../../../core/storage/folder_preview_cache.dart';

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
    this.onToggleStarPdf,
    this.starredUris = const <String>{},
    this.onTrashPdf,
    this.initialPath = '',
    this.embedded = false,
    this.isLoading = false,
    this.onRefresh,
    this.cacheScope = '',
  });

  final String rootName;
  final List<Map<String, Object?>> entries;
  final Future<void> Function(String uri, String name) onOpenPdf;
  final Future<bool> Function(String uri, String name)? onMovePdf;
  final Future<bool> Function(String uri, String name)? onRenamePdf;
  final Future<void> Function(String uri, String name)? onSharePdf;
  final Future<void> Function(String uri, String name)? onToggleStarPdf;
  final Set<String> starredUris;
  final Future<bool> Function(String uri, String name)? onTrashPdf;
  final String initialPath;
  final bool embedded;
  final bool isLoading;
  final Future<void> Function()? onRefresh;
  /// Identifies the granted storage roots, preventing stale cross-root reuse.
  final String cacheScope;

  @override
  State<PhoneStorageBrowserScreen> createState() =>
      _PhoneStorageBrowserScreenState();
}

class _PhoneStorageBrowserScreenState extends State<PhoneStorageBrowserScreen> {
  String? _selectedFolderPath;
  late final TextEditingController _searchController;
  StorageSortField _sortField = StorageSortField.name;
  bool _sortAscending = true;
  int _sortRevision = 0;
  List<Map<String, Object?>>? _groupedEntries;
  StorageSortField? _groupedSortField;
  bool? _groupedSortAscending;
  Map<String, List<Map<String, Object?>>>? _groupedCache;
  FolderPreview? _savedSelectedPreview;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    unawaited(_restoreSortPreference());
    // Initial paths from MediaStore/Recent may include the synthetic
    // "Internal/" volume label; browser folder keys are root-relative.
    _selectedFolderPath =
        widget.initialPath.isEmpty ? null : _rootRelativePath(widget.initialPath);
    if (_selectedFolderPath != null) {
      unawaited(_restoreSelectedPreview(_selectedFolderPath!));
    }
  }

  @override
  void didUpdateWidget(covariant PhoneStorageBrowserScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selected = _selectedFolderPath;
    if (selected != null && oldWidget.cacheScope != widget.cacheScope) {
      _savedSelectedPreview = null;
      unawaited(_restoreSelectedPreview(selected));
    }
    if (selected != null && oldWidget.entries != widget.entries) {
      _scheduleSelectedPreviewWrite(selected);
    }
  }

  void _selectFolder(String path) {
    setState(() {
      _selectedFolderPath = path;
      _savedSelectedPreview = null;
    });
    // Let Flutter paint the newly selected folder before any cache work.
    _scheduleSelectedPreviewWrite(path);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _selectedFolderPath == path) {
        unawaited(_restoreSelectedPreview(path));
      }
    });
  }

  void _scheduleSelectedPreviewWrite(String path) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _selectedFolderPath == path) {
        unawaited(_saveSelectedFolderPreview(path));
      }
    });
  }

  Future<void> _restoreSelectedPreview(String path) async {
    if (widget.cacheScope.isEmpty ||
        (_directPdfFolders[path]?.isNotEmpty ?? false)) return;
    final scope = widget.cacheScope;
    final saved = await FolderPreviewCache.read(
      FolderPreviewCache.phoneKey(scope, path),
    );
    if (saved == null || !mounted ||
        _selectedFolderPath != path || widget.cacheScope != scope) return;
    setState(() => _savedSelectedPreview = saved);
  }

  Future<void> _saveSelectedFolderPreview(String path) async {
    if (widget.cacheScope.isEmpty) return;
    final files = _directPdfFolders[path];
    if (files == null || files.isEmpty) return;
    final preview = FolderPreview(
      key: FolderPreviewCache.phoneKey(widget.cacheScope, path),
      savedAt: DateTime.now().toUtc(),
      items: [
        for (final file in files)
          if (_isPdfFile(file))
            FolderPreviewItem(
              name: file['name'] as String,
              isFolder: false,
              sizeBytes: (file['sizeBytes'] as num?)?.toInt() ?? 0,
            ),
      ],
    );
    await FolderPreviewCache.write(preview);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _restoreSortPreference() async {
    final revision = _sortRevision;
    final saved = await StorageSortPreference.load(StorageSortPreference.phoneKey);
    if (!mounted || _sortRevision != revision || saved == null) return;
    setState(() {
      _sortField = saved.field;
      _sortAscending = saved.ascending;
    });
  }

  void _changeSort({StorageSortField? field, bool? ascending}) {
    _sortRevision++;
    setState(() {
      if (field != null) _sortField = field;
      if (ascending != null) _sortAscending = ascending;
    });
    unawaited(StorageSortPreference.save(
      StorageSortPreference.phoneKey,
      field: _sortField,
      ascending: _sortAscending,
      explicit: true,
    ).catchError((Object _) {
      // User's immediate in-memory selection still works if OS storage fails.
    }));
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
    // "Internal" is the virtual folder for PDFs at the volume root.
    // A pending Recycle Bin placeholder still needs to appear when the
    // root's last PDF has been deleted; otherwise path normalization hides it.
    if (entry['isPending'] == true &&
        _normalizePath(rawValue).toLowerCase() == 'internal') {
      return 'Internal';
    }
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

  DateTime? _modifiedAt(Map<String, Object?> entry) {
    final value = entry['lastModified'];
    if (value is num && value > 0) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }
    if (value is String) return DateTime.tryParse(value);
    if (value is DateTime) return value;
    return null;
  }

  int _comparePdfs(Map<String, Object?> a, Map<String, Object?> b) {
    final result = compareStorageItems(
      nameA: a['name'] as String,
      nameB: b['name'] as String,
      dateA: _modifiedAt(a),
      dateB: _modifiedAt(b),
      field: _sortField,
      ascending: _sortAscending,
    );
    if (result != 0) return result;
    return (a['uri'] as String).compareTo(b['uri'] as String);
  }

  Map<String, List<Map<String, Object?>>> get _directPdfFolders {
    // Search, Favorites and partial UI updates should not sort all PDFs
    // again unless the source snapshot or sorting preference changed.
    final cached = _groupedCache;
    if (cached != null &&
        identical(_groupedEntries, widget.entries) &&
        _groupedSortField == _sortField &&
        _groupedSortAscending == _sortAscending) return cached;
    final grouped = <String, List<Map<String, Object?>>>{};
    // Cache directory dates once. Calculating them during every sort
    // comparison would turn large libraries into quadratic work.
    final lastModifiedByFolder = <String, DateTime>{};
    for (final pdf in _pdfs) {
      final rawPath = _normalizedFolderPath(pdf);
      // Files directly under the storage root belong in a virtual Internal
      // folder instead of being silently omitted.
      final path = rawPath.isEmpty ? 'Internal' : rawPath;
      (grouped[path] ??= <Map<String, Object?>>[]).add(pdf);
      final date = _modifiedAt(pdf);
      final previous = lastModifiedByFolder[path];
      if (date != null && (previous == null || date.isAfter(previous))) {
        lastModifiedByFolder[path] = date;
      }
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
        final directoryDate = _modifiedAt(entry);
        final previous = lastModifiedByFolder[path];
        if (directoryDate != null &&
            (previous == null || directoryDate.isAfter(previous))) {
          lastModifiedByFolder[path] = directoryDate;
        }
      }
    }
    final sorted = grouped.keys.toList()
      ..sort((a, b) => compareStorageItems(
            nameA: a,
            nameB: b,
            dateA: lastModifiedByFolder[a],
            dateB: lastModifiedByFolder[b],
            field: _sortField,
            ascending: _sortAscending,
          ));
    final result = <String, List<Map<String, Object?>>>{
      for (final path in sorted)
        path: grouped[path]!..sort(_comparePdfs),
    };
    _groupedEntries = widget.entries;
    _groupedSortField = _sortField;
    _groupedSortAscending = _sortAscending;
    _groupedCache = result;
    return result;
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
    } else if (action == 'favorite') {
      await widget.onToggleStarPdf?.call(uri, name);
    } else if (action == 'location') {
      await _showFileLocation(entry);
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

  Future<void> _showFileLocation(Map<String, Object?> entry) async {
    final folderPath = _normalizedFolderPath(entry);
    final original = (entry['folderPath'] ?? entry['path'] ?? '').toString();
    final external = _normalizePath(original).startsWith('External storage');
    final display = external
        ? _normalizePath(original)
        : folderPath.isEmpty ? widget.rootName : _displayPath(folderPath);
    final openFolder = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('File Location'),
        content: SelectableText(display),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Open folder'),
          ),
        ],
      ),
    );
    if (openFolder == true && mounted) {
      _selectFolder(folderPath.isEmpty ? 'Internal' : folderPath);
    }
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          Expanded(
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
          ),
          StorageSortControls(
            field: _sortField,
            ascending: _sortAscending,
            onFieldChanged: (field) => _changeSort(field: field),
            onAscendingChanged: (value) => _changeSort(ascending: value),
          ),
        ],
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
    final inRecycleBin = (directory?['trashPdfCount'] as num?)?.toInt() ?? 0;
    return ListTile(
      key: ValueKey('phone-folder-$path'),
      leading: const Icon(Icons.folder_outlined),
      title: Text(
        _folderName(path),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(inRecycleBin == 0
          ? '$count PDFs · ${_formatSize(bytes)}'
          : '$count PDFs · $inRecycleBin in Recycle Bin'),
      onTap: () => _selectFolder(path),
      trailing: PopupMenuButton<String>(
        tooltip: 'Folder details and actions',
        onSelected: (value) {
          if (value == 'open') _selectFolder(path);
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
      key: ValueKey('phone-pdf-$uri'),
      leading: DocumentThumbnail(
        key: ValueKey('phone-thumbnail-$uri'),
        documentId: 'phone_$uri',
        storagePath: uri,
        sizeBytes: sizeBytes,
        sourceLastModifiedMillis: thumbnailModifiedMillis(entry['lastModified']),
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
          if (widget.onSharePdf != null)
            const PopupMenuItem(value: 'share', child: Text('Share PDF')),
          if (widget.onToggleStarPdf != null)
            PopupMenuItem(
              value: 'favorite',
              child: Text(widget.starredUris.contains(uri)
                  ? 'Remove from Star' : 'Add to Star'),
            ),
          if (widget.onRenamePdf != null)
            const PopupMenuItem(value: 'rename', child: Text('Rename')),
          if (widget.onMovePdf != null)
            const PopupMenuItem(value: 'move', child: Text('Move to Grid')),
          if (widget.onTrashPdf != null)
            const PopupMenuItem(value: 'trash', child: Text('Delete')),
          const PopupMenuItem(value: 'location', child: Text('File Location')),
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
    }).toList(growable: false)..sort(_comparePdfs);

    final isSearching = query.isNotEmpty;
    var visiblePdfCount = matchingPdfs.length;
    final children = <WidgetBuilder>[];
    if (selectedPath == null) {
      if (folderPaths.isNotEmpty) {
        children.add((context) => 
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('FOLDERS',
                style: Theme.of(context).textTheme.labelLarge),
          ),
        );
        for (final path in folderPaths) {
          children.add((context) => _buildFolderTile(path, folders[path]!));
        }
      }
      if (isSearching && matchingPdfs.isNotEmpty) {
        children.add((context) => 
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('PDF FILES',
                style: Theme.of(context).textTheme.labelLarge),
          ),
        );
        for (final entry in matchingPdfs) {
          final path = _normalizedFolderPath(entry);
          children.add((context) => _buildPdfTile(
            entry,
            locationLabel: path.isEmpty ? 'Internal' : _displayPath(path),
          ));
        }
      }
      if (children.isEmpty) {
        children.add((context) => 
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
      if (visibleFiles.isEmpty && widget.isLoading &&
          _savedSelectedPreview != null && !isSearching) {
        // Read-only cold preview: no edit/share/delete actions from stale data.
        final saved = _savedSelectedPreview!;
        visiblePdfCount = saved.pdfCount;
        children.add((context) => const ListTile(
          leading: Icon(Icons.history),
          title: Text('Saved folder preview · verifying PDFs'),
        ));
        for (final item in saved.items) {
          children.add((context) => ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(_formatSize(item.sizeBytes)),
          ));
        }
      } else if (visibleFiles.isEmpty) {
        children.add((context) => Padding(
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
        ));
      } else {
        for (final entry in visibleFiles) {
          children.add((context) => _buildPdfTile(entry));
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
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: children.length,
              itemBuilder: (context, index) => children[index](context),
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
