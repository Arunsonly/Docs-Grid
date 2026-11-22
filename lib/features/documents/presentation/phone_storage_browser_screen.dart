import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/widgets/storage_sort_controls.dart';
import '../../../core/storage/folder_preview_cache.dart';

import 'document_thumbnail.dart';
import 'ocr_search_mode_control.dart';
import '../data/phone_ocr_search_index.dart';
import '../../tools/document_tools_service.dart';

class PhoneStorageBrowserScreen extends StatefulWidget {
  const PhoneStorageBrowserScreen({
    super.key,
    required this.rootName,
    required this.entries,
    required this.onOpenPdf,
    this.onMovePdf,
    this.onMoveWithinPhone,
    this.onRenamePdf,
    this.onSharePdf,
    this.onShareSelectedPdfs,
    this.onMoveSelectedWithinPhone,
    this.onTrashSelectedPdfs,
    this.onToggleStarPdf,
    this.starredUris = const <String>{},
    this.onTrashPdf,
    this.initialPath = '',
    this.embedded = false,
    this.isLoading = false,
    this.onRefresh,
    this.cacheScope = '',
    this.ocrSearchAvailable = false,
    this.ocrTextExtractor,
  });

  final String rootName;
  final List<Map<String, Object?>> entries;
  final Future<void> Function(String uri, String name) onOpenPdf;
  final Future<bool> Function(String uri, String name)? onMovePdf;
  final Future<bool> Function(String uri, String name)? onMoveWithinPhone;
  final Future<bool> Function(String uri, String name)? onRenamePdf;
  final Future<void> Function(String uri, String name)? onSharePdf;
  /// One native share sheet for all selected source PDFs.
  final Future<void> Function(List<Map<String, Object?>> selected)?
      onShareSelectedPdfs;
  /// Batch handlers choose a destination/confirm once and preserve per-file
  /// verification. Returning true means at least one source changed.
  final Future<bool> Function(List<Map<String, Object?>> selected)?
      onMoveSelectedWithinPhone;
  final Future<bool> Function(List<Map<String, Object?>> selected)?
      onTrashSelectedPdfs;
  final Future<void> Function(String uri, String name)? onToggleStarPdf;
  final Set<String> starredUris;
  final Future<bool> Function(String uri, String name)? onTrashPdf;
  final String initialPath;
  final bool embedded;
  final bool isLoading;
  final Future<void> Function()? onRefresh;
  /// Identifies the granted storage roots, preventing stale cross-root reuse.
  final String cacheScope;
  final bool ocrSearchAvailable;
  /// Optional for tests; production uses the existing local OCR engine.
  final PhonePdfTextExtractor? ocrTextExtractor;

  @override
  State<PhoneStorageBrowserScreen> createState() =>
      _PhoneStorageBrowserScreenState();
}

class _PhoneStorageBrowserScreenState extends State<PhoneStorageBrowserScreen> {
  String? _selectedFolderPath;
  final Set<String> _selectedPdfUris = <String>{};
  bool _isSelectingPdfs = false;
  bool _selectionBusy = false;
  late final TextEditingController _searchController;
  late final PhoneOcrSearchIndex _ocrIndex;
  Timer? _ocrDebounce;
  bool _ocrSelected = false;
  bool _ocrIndexing = false;
  int _ocrEpoch = 0;
  int _ocrCompleted = 0;
  int _ocrTotal = 0;
  String? _ocrMessage;
  StorageSortField _sortField = StorageSortField.name;
  bool _sortAscending = true;
  int _sortRevision = 0;
  List<Map<String, Object?>>? _groupedEntries;
  StorageSortField? _groupedSortField;
  bool? _groupedSortAscending;
  Map<String, List<Map<String, Object?>>>? _groupedCache;
  List<Map<String, Object?>>? _cachedPdfRows;
  List<Map<String, Object?>>? _cachedPdfSource;
  FolderPreview? _savedSelectedPreview;
  // Phone's complete indexed metadata is already available. Build only the
  // first visible rows; reveal later rows progressively on demand.
  static const int _renderPageSize = 60;
  int _visibleFolderLimit = _renderPageSize;
  int _visiblePdfLimit = _renderPageSize;
  bool _hasMoreFolderRows = false;
  bool _hasMorePdfRows = false;
  bool _nextRenderPageScheduled = false;

  void _resetVisiblePages() {
    _visibleFolderLimit = _renderPageSize;
    _visiblePdfLimit = _renderPageSize;
    _hasMoreFolderRows = false;
    _hasMorePdfRows = false;
  }

  void _showMoreVisibleRows() {
    if (!mounted) return;
    setState(() {
      if (_hasMoreFolderRows) {
        _visibleFolderLimit += _renderPageSize;
      } else if (_hasMorePdfRows) {
        _visiblePdfLimit += _renderPageSize;
      }
    });
  }

  void _loadMoreOnScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.extentAfter > 1000 ||
        (notification is ScrollUpdateNotification &&
            (notification.scrollDelta ?? 0) <= 0) ||
        (notification is OverscrollNotification &&
            notification.overscroll <= 0) ||
        (!_hasMoreFolderRows && !_hasMorePdfRows) ||
        _nextRenderPageScheduled ||
        (notification is! ScrollUpdateNotification &&
            notification is! OverscrollNotification)) return;
    _nextRenderPageScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nextRenderPageScheduled = false;
      if (mounted && (_hasMoreFolderRows || _hasMorePdfRows)) {
        _showMoreVisibleRows();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _ocrIndex = PhoneOcrSearchIndex(widget.ocrTextExtractor ??
        DocumentToolsService().extractPhonePdfTextFromUri);
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
    if (oldWidget.ocrSearchAvailable && !widget.ocrSearchAvailable) {
      _ocrEpoch++;
      _ocrDebounce?.cancel();
      _ocrSelected = false;
      _ocrMessage = null;
      _ocrIndex.clear();
    }
    if (widget.ocrSearchAvailable && _ocrSelected &&
        oldWidget.entries != widget.entries) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_runPhoneOcr());
      });
    }
    if (oldWidget.cacheScope != widget.cacheScope) {
      _resetVisiblePages();
      _selectedPdfUris.clear();
      _isSelectingPdfs = false;
    } else if (oldWidget.entries != widget.entries) {
      // Selection must never act on stale URIs after a Phone refresh/move.
      final existing = widget.entries.where(_isPdfFile)
          .map((entry) => entry['uri'] as String).toSet();
      _selectedPdfUris.removeWhere((uri) => !existing.contains(uri));
    }
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
      _selectedPdfUris.clear();
      _isSelectingPdfs = false;
      _savedSelectedPreview = null;
      _resetVisiblePages();
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
    _ocrEpoch++;
    _ocrDebounce?.cancel();
    _ocrIndex.clear();
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
      _resetVisiblePages();
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

  List<Map<String, Object?>> get _pdfs {
    if (identical(widget.entries, _cachedPdfSource) &&
        _cachedPdfRows != null) return _cachedPdfRows!;
    final result = widget.entries.where(_isPdfFile).toList(growable: false);
    _cachedPdfSource = widget.entries;
    _cachedPdfRows = result;
    return result;
  }

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


  void _startPdfSelection(Map<String, Object?> entry) {
    final uri = entry['uri'] as String;
    setState(() {
      _isSelectingPdfs = true;
      _selectedPdfUris.add(uri);
    });
  }

  void _togglePdfSelection(Map<String, Object?> entry) {
    final uri = entry['uri'] as String;
    setState(() {
      _isSelectingPdfs = true;
      if (!_selectedPdfUris.add(uri)) _selectedPdfUris.remove(uri);
    });
  }

  void _clearPdfSelection() {
    if (!_isSelectingPdfs) return;
    setState(() {
      _isSelectingPdfs = false;
      _selectedPdfUris.clear();
    });
  }

  List<Map<String, Object?>> _selectionScopePdfs() {
    final query = _searchController.text.trim().toLowerCase();
    final folder = _selectedFolderPath;
    if (folder == null && query.isEmpty) return const <Map<String, Object?>>[];
    final source = folder == null
        ? _pdfs
        : (_directPdfFolders[folder] ?? const <Map<String, Object?>>[]);
    if (query.isEmpty) return source;
    if (_ocrSelected) return _ocrIndex.matches(source, query);
    return source.where((entry) {
      final name = (entry['name'] as String).toLowerCase();
      if (folder != null) return name.contains(query);
      return name.contains(query) ||
          _normalizedFolderPath(entry).toLowerCase().contains(query);
    }).toList(growable: false);
  }

  List<Map<String, Object?>> _selectedPdfRows() =>
      _pdfs.where((entry) => _selectedPdfUris.contains(entry['uri']))
          .toList(growable: false);

  void _selectAllVisiblePdfs() {
    final ids = _selectionScopePdfs().map((row) => row['uri'] as String).toSet();
    if (ids.isEmpty) return;
    setState(() {
      if (_selectedPdfUris.containsAll(ids)) {
        _selectedPdfUris.removeAll(ids);
      } else {
        _selectedPdfUris.addAll(ids);
      }
    });
  }

  Future<void> _showSelectedPdfDetails() async {
    final chosen = _selectedPdfRows();
    if (chosen.isEmpty) return;
    var total = 0;
    for (final entry in chosen) {
      final bytes = (entry['sizeBytes'] as num?)?.toInt() ??
          (entry['size'] as num?)?.toInt() ?? 0;
      if (bytes > 0) total += bytes;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Selection Details'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Selected PDFs: ${chosen.length}'),
            const SizedBox(height: 8),
            Text('Total PDF size: ${_formatSize(total)}'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _runSelectedPdfAction(String action) async {
    if (_selectionBusy) return;
    final chosen = _selectedPdfRows();
    if (chosen.isEmpty) return;
    setState(() => _selectionBusy = true);
    var changed = false;
    try {
      if (action == 'share') {
        if (widget.onShareSelectedPdfs != null) {
          await widget.onShareSelectedPdfs!(chosen);
        } else if (chosen.length == 1) {
          await widget.onSharePdf?.call(
              chosen.single['uri'] as String, chosen.single['name'] as String);
        }
      } else if (action == 'move') {
        changed = await widget.onMoveSelectedWithinPhone?.call(chosen) ??
            (chosen.length == 1
                ? await widget.onMoveWithinPhone?.call(
                      chosen.single['uri'] as String,
                      chosen.single['name'] as String) ?? false
                : false);
      } else if (action == 'trash') {
        changed = await widget.onTrashSelectedPdfs?.call(chosen) ??
            (chosen.length == 1
                ? await widget.onTrashPdf?.call(
                      chosen.single['uri'] as String,
                      chosen.single['name'] as String) ?? false
                : false);
      }
      if (!mounted) return;
      if (changed) {
        _clearPdfSelection();
        await widget.onRefresh?.call();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Selected PDF action failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _selectionBusy = false);
    }
  }

  Widget _buildPdfSelectionToolbar() {
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('phone-pdf-floating-selection-bar'),
      elevation: 7,
      shadowColor: colors.shadow.withValues(alpha: 0.25),
      color: colors.secondaryContainer,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
        child: Row(children: [
          IconButton(
            key: const ValueKey('phone-pdf-select-all'),
            tooltip: 'Select all PDFs',
            onPressed: _selectionBusy ? null : _selectAllVisiblePdfs,
            icon: const Icon(Icons.select_all),
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: Text(
              '${_selectedPdfUris.length} selected',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            key: const ValueKey('phone-pdf-share-selected'),
            tooltip: 'Share selected PDFs',
            onPressed: _selectionBusy || _selectedPdfUris.isEmpty ||
                    (widget.onShareSelectedPdfs == null &&
                        widget.onSharePdf == null)
                ? null : () => unawaited(_runSelectedPdfAction('share')),
            icon: const Icon(Icons.share_outlined),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            key: const ValueKey('phone-pdf-move-selected'),
            tooltip: 'Move selected PDFs',
            onPressed: _selectionBusy || _selectedPdfUris.isEmpty ||
                    (widget.onMoveSelectedWithinPhone == null &&
                        widget.onMoveWithinPhone == null)
                ? null : () => unawaited(_runSelectedPdfAction('move')),
            icon: const Icon(Icons.drive_file_move_outlined),
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            key: const ValueKey('phone-pdf-delete-selected'),
            tooltip: 'Move selected PDFs to Recycle Bin',
            onPressed: _selectionBusy || _selectedPdfUris.isEmpty ||
                    (widget.onTrashSelectedPdfs == null &&
                        widget.onTrashPdf == null)
                ? null : () => unawaited(_runSelectedPdfAction('trash')),
            icon: const Icon(Icons.delete_outline),
            visualDensity: VisualDensity.compact,
          ),
          PopupMenuButton<String>(
            key: const ValueKey('phone-pdf-selected-more'),
            tooltip: 'PDF selection actions',
            enabled: !_selectionBusy,
            icon: const Icon(Icons.more_vert),
            onSelected: (action) {
              if (action == 'details') {
                unawaited(_showSelectedPdfDetails());
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem<String>(
                value: 'details',
                enabled: _selectedPdfUris.isNotEmpty,
                child: const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.info_outline),
                  title: Text('Details'),
                ),
              ),
            ],
          ),
        ]),
      ),
    );
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
    } else if (action == 'move_phone') {
      sourceChanged = await widget.onMoveWithinPhone?.call(uri, name) ?? false;
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

  void _setOcrSelected(bool enabled) {
    if (!widget.ocrSearchAvailable || enabled == _ocrSelected) return;
    _ocrDebounce?.cancel();
    if (!enabled) {
      _ocrEpoch++;
      _ocrIndex.clear();
    }
    setState(() {
      _ocrSelected = enabled;
      _ocrMessage = null;
      _resetVisiblePages();
    });
    if (enabled) _schedulePhoneOcr();
  }

  void _schedulePhoneOcr() {
    _ocrDebounce?.cancel();
    if (!widget.ocrSearchAvailable || !_ocrSelected ||
        _searchController.text.trim().isEmpty) return;
    _ocrDebounce = Timer(const Duration(milliseconds: 280), () {
      if (mounted) unawaited(_runPhoneOcr());
    });
  }

  Future<void> _runPhoneOcr() async {
    if (!mounted || !widget.ocrSearchAvailable || !_ocrSelected ||
        _searchController.text.trim().isEmpty || _ocrIndexing) return;
    final run = ++_ocrEpoch;
    setState(() {
      _ocrIndexing = true;
      _ocrCompleted = 0;
      _ocrTotal = 0;
      _ocrMessage = null;
    });
    try {
      final result = await _ocrIndex.indexEntries(
        _pdfs,
        shouldCancel: () => !mounted || !_ocrSelected ||
            !widget.ocrSearchAvailable || run != _ocrEpoch,
        onProgress: (completed, total) {
          if (!mounted || run != _ocrEpoch) return;
          // Progress and content results are available immediately.
          setState(() {
            _ocrCompleted = completed;
            _ocrTotal = total;
            _resetVisiblePages();
          });
        },
      );
      if (mounted && run == _ocrEpoch) {
        setState(() {
          _ocrMessage = result.failed == 0
              ? 'Phone OCR search ready'
              : 'OCR completed; ${result.failed} PDFs could not be read.';
        });
      }
    } on OcrIndexCancelled {
      // User switched back to name search or left this screen.
    } catch (error) {
      if (mounted && run == _ocrEpoch) {
        setState(() => _ocrMessage = 'Phone OCR unavailable: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _ocrIndexing = false);
        if (run != _ocrEpoch && _ocrSelected &&
            widget.ocrSearchAvailable &&
            _searchController.text.trim().isNotEmpty) {
          unawaited(_runPhoneOcr());
        }
      }
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
              onChanged: (_) {
                setState(_resetVisiblePages);
                if (_ocrSelected) _schedulePhoneOcr();
              },
              decoration: InputDecoration(
                hintText: _ocrSelected
                    ? 'Search text inside Phone PDFs'
                    : 'Search phone folders or PDF names',
                prefixIcon: const Icon(Icons.search),
                suffixIconConstraints: const BoxConstraints(
                    minHeight: 48, minWidth: 0),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.ocrSearchAvailable)
                      OcrSearchModeControl(
                        searchInsidePdf: _ocrSelected,
                        onChanged: _setOcrSelected,
                      ),
                    if (_searchController.text.isNotEmpty)
                      IconButton(
                        tooltip: 'Clear search',
                        onPressed: () {
                          _searchController.clear();
                          _ocrDebounce?.cancel();
                          _ocrEpoch++;
                          setState(_resetVisiblePages);
                        },
                        icon: const Icon(Icons.close),
                      ),
                  ],
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
          if (widget.onMoveWithinPhone != null)
            const PopupMenuItem(value: 'move_phone', child: Text('Move')),
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
        .where((path) => query.isEmpty ||
            (!_ocrSelected &&
             (selectedPath != null || path.toLowerCase().contains(query))))
        .toList(growable: false);
    // A selected folder renders its already sorted direct children.
    // At the root without a search, count PDFs without sorting all of them.
    // Only real search results need a cross-folder sort.
    final List<Map<String, Object?>> matchingPdfs;
    if (selectedPath != null) {
      matchingPdfs = const <Map<String, Object?>>[];
    } else if (query.isEmpty) {
      matchingPdfs = _pdfs;
    } else if (_ocrSelected) {
      matchingPdfs = _ocrIndex.matches(_pdfs, query)..sort(_comparePdfs);
    } else {
      matchingPdfs = _pdfs.where((entry) {
        final name = (entry['name'] as String).toLowerCase();
        final folderPath = _normalizedFolderPath(entry).toLowerCase();
        return name.contains(query) || folderPath.contains(query);
      }).toList(growable: false)..sort(_comparePdfs);
    }

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
        for (final path in folderPaths.take(_visibleFolderLimit)) {
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
        for (final entry in matchingPdfs.take(_visiblePdfLimit)) {
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
          ? _ocrSelected
              ? _ocrIndex.matches(selectedFiles, query)
              : selectedFiles.where((entry) {
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
        for (final item in saved.items.take(_visiblePdfLimit)) {
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
        for (final entry in visibleFiles.take(_visiblePdfLimit)) {
          children.add((context) => _buildPdfTile(entry));
        }
      }
    }

    _hasMoreFolderRows = selectedPath == null &&
        folderPaths.length > _visibleFolderLimit;
    _hasMorePdfRows = selectedPath == null
        ? isSearching && matchingPdfs.length > _visiblePdfLimit
        : visiblePdfCount > _visiblePdfLimit;
    if (_hasMoreFolderRows || _hasMorePdfRows) {
      children.add((context) => ListTile(
        key: const ValueKey('phone-next-page'),
        leading: const Icon(Icons.expand_more),
        title: const Text('Load more'),
        onTap: _showMoreVisibleRows,
      ));
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
        if (widget.ocrSearchAvailable && _ocrSelected) ...[
          if (_ocrIndexing)
            LinearProgressIndicator(
              value: _ocrTotal == 0 ? null : _ocrCompleted / _ocrTotal,
              minHeight: 2,
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              _ocrIndexing
                  ? 'Reading Phone PDFs locally: $_ocrCompleted / $_ocrTotal'
                  : _ocrMessage ??
                      'Enter a term to find text inside Phone PDFs.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
        if (widget.isLoading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              _loadMoreOnScroll(notification);
              return false;
            },
            child: RefreshIndicator(
              onRefresh: widget.onRefresh ?? () async {},
              child: ListView.builder(
                key: ValueKey('phone-browser-${selectedPath ?? '__root__'}-${_sortField.name}-$_sortAscending-$query'),
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: children.length,
                itemBuilder: (context, index) => children[index](context),
              ),
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
