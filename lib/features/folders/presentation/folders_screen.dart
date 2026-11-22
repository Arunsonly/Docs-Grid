import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/widgets/storage_sort_controls.dart';

import '../../documents/data/document_repository.dart';
import '../../documents/presentation/document_thumbnail.dart';
import '../../documents/presentation/ocr_search_mode_control.dart';
import '../../tools/document_tools_service.dart';
import '../../../core/storage/storage_location_service.dart';
import '../../../core/storage/folder_preview_cache.dart';
import '../../../core/storage/portable_snapshot_events.dart';
import '../../reminders/data/reminder_repository.dart';
import '../../categories/data/category_repository.dart';

import '../data/folder_repository.dart';
import '../domain/folder.dart';

class FoldersScreen extends StatefulWidget {
  const FoldersScreen({
    super.key,
    this.folderRepository,
    this.documentRepository,
    this.ocrSearchAvailable = false,
    this.ocrTools,
    this.onOpenSettings,
  });

  // Optional dependencies permit complete widget regression tests without
  // changing normal app construction or storage ownership.
  final FolderRepository? folderRepository;
  final DocumentRepository? documentRepository;
  final bool ocrSearchAvailable;
  final DocumentToolsService? ocrTools;
  final VoidCallback? onOpenSettings;

  @override
  State<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends State<FoldersScreen>
    with WidgetsBindingObserver {
  late final FolderRepository _repository =
      widget.folderRepository ?? FolderRepository();
  late final DocumentRepository _documents =
      widget.documentRepository ?? DocumentRepository();
  late final DocumentToolsService _ocrTools =
      widget.ocrTools ?? DocumentToolsService();
  final CategoryRepository _categories = CategoryRepository();
  final List<Folder> _ancestors = [];
  String? _currentFolderId;
  String _currentTitle = 'Folders';
  final Set<String> _selectedDocumentIds = <String>{};
  bool _isSelectingDocuments = false;
  final Set<String> _selectedFolderIds = <String>{};
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _ocrSelected = false;
  bool _ocrBusy = false;
  int _ocrEpoch = 0;
  int _ocrDone = 0;
  int _ocrTotal = 0;
  String? _ocrMessage;
  StorageSortField _sortField = StorageSortField.name;
  bool _sortAscending = true;
  // Respect the existing user-defined folder order until sorting is chosen.
  bool _explicitSort = false;
  int _sortRevision = 0;
  bool _isSelectingFolders = false;
  bool _isReorderingFolders = false;
  // Presentation only: folder and PDF repositories keep identical queries.
  bool _showGridTiles = false;
  int _viewPreferenceRevision = 0;
  static const String _viewPreferenceKey = 'docsgrid_grid_tab_tiles_v1';
  List<Folder> _draftFolderOrder = <Folder>[];
  late Future<List<Folder>> _foldersFuture;
  late Future<List<DocumentRecord>> _documentsFuture;
  static const int _gridPageSize = 60;
  bool _pagedDocumentsMode = false;
  List<DocumentRecord> _pagedDocuments = const [];
  int _pagedTotalCount = 0;
  String? _nextDocumentName;
  String? _nextDocumentId;
  bool _hasMoreFolderDocuments = false;
  bool _loadingMoreFolderDocuments = false;
  bool _pageLoadFailed = false;
  bool _morePageScheduled = false;
  // At most one additional SQLite page is held in memory. This is metadata,
  // not PDF data or thumbnails, and is invalidated on every folder reload.
  Future<FolderDocumentPage?>? _nextPagePrefetch;
  String? _nextPagePrefetchCursor;
  final Map<String, FolderPreview> _savedFolderPreviews = {};
  static const int _maxMemoryFolderPreviews = 12;

  void _rememberFolderPreview(FolderPreview preview) {
    // Keep only recently visited previews in RAM, independent of the
    // bounded persistent on-disk index.
    _savedFolderPreviews.remove(preview.key);
    _savedFolderPreviews[preview.key] = preview;
    while (_savedFolderPreviews.length > _maxMemoryFolderPreviews) {
      _savedFolderPreviews.remove(_savedFolderPreviews.keys.first);
    }
  }
  final Set<String> _loadingFolderPreviews = {};
  final Set<String> _suppressFolderPreviews = {};
  int _folderLoadEpoch = 0;
  StreamSubscription<GridFolderChange>? _gridChangesSubscription;
  int _folderPreviewRevision = 0;
  bool _allGridPreviewsInvalidating = false;
  final Set<String> _pendingGridPreviewInvalidations = {};
  Timer? _gridPreviewInvalidationDebounce;
  Set<String?>? _queuedGridPreviewIds = <String?>{};
  Completer<void>? _gridPreviewInvalidationDone;
  bool _gridPreviewRebuildScheduled = false;
  // Only prepare metadata of the first two likely child folders, and only
  // after the current screen has loaded and the user has stopped scrolling.
  Timer? _idleFolderPrefetchTimer;
  List<Folder> _prefetchFolderCandidates = const [];
  int _prefetchFolderEpoch = -1;
  bool _prefetchingChildFolders = false;
  bool _gridScreenForeground = true;
  final Set<String> _attemptedChildPrefetches = {};
  static const int _maxPrefetchChildFolders = 2;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _gridChangesSubscription =
        PortableSnapshotEvents.gridPreviewChanges.listen(_onGridFolderChange);
    _load();
    unawaited(_restoreSortPreference());
    unawaited(_restoreViewPreference());
  }

  @override
  void dispose() {
    _ocrEpoch++;
    _idleFolderPrefetchTimer?.cancel();
    if (_gridPreviewInvalidationDebounce?.isActive == true) {
      _gridPreviewInvalidationDebounce?.cancel();
      // Do not lose an invalidation because the user leaves this tab.
      unawaited(_flushPreviewInvalidation(
        _queuedGridPreviewIds, _folderPreviewRevision,
      ));
    }
    _gridChangesSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _gridScreenForeground = state == AppLifecycleState.resumed;
    if (!_gridScreenForeground) {
      _idleFolderPrefetchTimer?.cancel();
    } else {
      _queueIdleFolderPrefetch();
    }
  }

  void _onGridFolderChange(GridFolderChange change) {
    final affected = change.affectedFolderIds;
    if (affected != null && affected.isEmpty) return;
    final revision = ++_folderPreviewRevision;
    final currentKey = FolderPreviewCache.gridKey(_currentFolderId);
    final keys = affected?.map(FolderPreviewCache.gridKey).toSet();
    _idleFolderPrefetchTimer?.cancel();
    _prefetchFolderCandidates = const [];
    _prefetchFolderEpoch = -1;
    if (keys == null) {
      _savedFolderPreviews.clear();
      _attemptedChildPrefetches.clear();
      _allGridPreviewsInvalidating = true;
    } else {
      for (final key in keys) {
        _savedFolderPreviews.remove(key);
        _attemptedChildPrefetches.remove(key);
      }
      _pendingGridPreviewInvalidations.addAll(keys);
    }
    if (keys == null || keys.contains(currentKey)) {
      _suppressFolderPreviews.add(currentKey);
      if (!_gridPreviewRebuildScheduled) {
        _gridPreviewRebuildScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _gridPreviewRebuildScheduled = false;
          if (mounted) setState(() {});
        });
      }
    }
    // Group bursts of imports/moves into one disk operation per changed
    // folder; avoid rewriting/removing the same metadata hundreds of times.
    if (affected == null) {
      _queuedGridPreviewIds = null;
    } else {
      _queuedGridPreviewIds?.addAll(affected);
    }
    _gridPreviewInvalidationDone ??= Completer<void>();
    _gridPreviewInvalidationDebounce?.cancel();
    _gridPreviewInvalidationDebounce =
        Timer(const Duration(milliseconds: 120), () {
      final queued = _queuedGridPreviewIds;
      _queuedGridPreviewIds = <String?>{};
      unawaited(_flushPreviewInvalidation(queued, revision));
    });
  }

  Future<void> _flushPreviewInvalidation(
    Set<String?>? affected, int revision,
  ) async {
    try {
      await _invalidatePreviewMetadata(affected, revision);
    } finally {
      if (revision == _folderPreviewRevision) {
        final completed = _gridPreviewInvalidationDone;
        _gridPreviewInvalidationDone = null;
        if (completed != null && !completed.isCompleted) completed.complete();
      }
    }
  }

  Future<void> _persistVerifiedPreview(
    FolderPreview preview, int revision,
  ) async {
    // A fresh, verified cache write must not get deleted by an invalidation
    // from the mutation which triggered the current folder reload.
    final pending = _gridPreviewInvalidationDone?.future;
    if (pending != null) await pending;
    if (!mounted || revision != _folderPreviewRevision) return;
    await FolderPreviewCache.write(preview);
  }

  Future<void> _invalidatePreviewMetadata(
    Set<String?>? affected, int revision,
  ) async {
    try {
      await FolderPreviewCache.invalidateGridFolders(affected);
    } finally {
      if (!mounted || revision != _folderPreviewRevision) return;
      _allGridPreviewsInvalidating = false;
      _pendingGridPreviewInvalidations.clear();
      // Only verified SQLite/provider reads may repopulate an invalidated
      // view. External edits do not grant stale cached PDF actions.
    }
  }

  Future<void> _restoreSortPreference() async {
    final revision = _sortRevision;
    final saved = await StorageSortPreference.load(StorageSortPreference.gridKey);
    if (!mounted || revision != _sortRevision || saved == null) return;
    setState(() {
      _sortField = saved.field;
      _sortAscending = saved.ascending;
      _explicitSort = saved.explicit;
      // A saved custom sort must see the full result set before sorting it.
      if (saved.explicit && _pagedDocumentsMode) _reloadDocumentsOnly();
    });
  }

  void _changeSort({StorageSortField? field, bool? ascending}) {
    _sortRevision++;
    setState(() {
      if (field != null) _sortField = field;
      if (ascending != null) _sortAscending = ascending;
      _explicitSort = true;
      if (_pagedDocumentsMode) _reloadDocumentsOnly();
    });
    _saveSortPreference();
  }

  void _saveSortPreference() {
    unawaited(StorageSortPreference.save(
      StorageSortPreference.gridKey,
      field: _sortField,
      ascending: _sortAscending,
      explicit: _explicitSort,
    ).catchError((Object _) {
      // Only optional UI preference persistence failed; list remains usable.
    }));
  }

  Future<void> _restoreViewPreference() async {
    final revision = _viewPreferenceRevision;
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_viewPreferenceKey) ?? false;
      if (!mounted || revision != _viewPreferenceRevision) return;
      if (_showGridTiles != enabled) {
        setState(() => _showGridTiles = enabled);
      }
    } catch (_) {
      // Preferences are optional. The existing list remains fully usable.
    }
  }

  void _toggleGridListView() {
    if (_isReorderingFolders || _isSelectingFolders ||
        _isSelectingDocuments) return;
    setState(() {
      _viewPreferenceRevision++;
      _showGridTiles = !_showGridTiles;
    });
    final enabled = _showGridTiles;
    unawaited(SharedPreferences.getInstance().then((prefs) async {
      await prefs.setBool(_viewPreferenceKey, enabled);
    }).catchError((Object _) {
      // No data operation depends on the visual layout preference.
    }));
  }

  void _resetDocumentPages() {
    _pagedDocuments = const [];
    _pagedTotalCount = 0;
    _nextDocumentName = null;
    _nextDocumentId = null;
    _hasMoreFolderDocuments = false;
    _loadingMoreFolderDocuments = false;
    _pageLoadFailed = false;
    _morePageScheduled = false;
    _nextPagePrefetch = null;
    _nextPagePrefetchCursor = null;
  }

  Future<List<DocumentRecord>> _getFirstPage(
    String? folderId, int epoch,
  ) async {
    // Both queries are indexed. No full-document list is ever materialized
    // simply to determine an accurate PDF total.
    final values = await Future.wait<Object>([
      _documents.listInFolderPage(folderId, pageSize: _gridPageSize),
      _documents.countInFolder(folderId),
    ]);
    final page = values[0] as FolderDocumentPage;
    final count = values[1] as int;
    if (mounted && epoch == _folderLoadEpoch &&
        folderId == _currentFolderId && _pagedDocumentsMode) {
      _pagedDocuments = page.records;
      _pagedTotalCount = count;
      _hasMoreFolderDocuments = page.hasMore;
      _nextDocumentName = page.nextName;
      _nextDocumentId = page.nextId;
      _schedulePagePrefetch(epoch);
    }
    return page.records;
  }

  void _schedulePagePrefetch(int epoch) {
    if (!_pagedDocumentsMode || !_hasMoreFolderDocuments ||
        _nextDocumentName == null || _nextDocumentId == null) return;
    final folderId = _currentFolderId;
    final name = _nextDocumentName!;
    final id = _nextDocumentId!;
    final cursor = '$epoch:$folderId:$name:$id';
    // Start after painting the first frame; do not make folder entry slower.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || epoch != _folderLoadEpoch ||
          folderId != _currentFolderId || !_pagedDocumentsMode ||
          !_hasMoreFolderDocuments || _nextDocumentName != name ||
          _nextDocumentId != id) return;
      if (_nextPagePrefetchCursor == cursor) return;
      _nextPagePrefetchCursor = cursor;
      _nextPagePrefetch = _documents.listInFolderPage(
        folderId,
        pageSize: _gridPageSize,
        afterName: name,
        afterId: id,
      ).then<FolderDocumentPage?>(
        (page) => page,
        onError: (Object _, StackTrace __) => null,
      );
    });
  }

  @override
  void didUpdateWidget(covariant FoldersScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ocrSearchAvailable && !widget.ocrSearchAvailable) {
      _ocrEpoch++;
      _ocrSelected = false;
      _ocrMessage = null;
      _reloadDocumentsOnly();
    }
  }

  void _setOcrSelected(bool enabled) {
    if (!widget.ocrSearchAvailable || _ocrSelected == enabled) return;
    if (!enabled) _ocrEpoch++;
    setState(() {
      _ocrSelected = enabled;
      _ocrMessage = null;
      _reloadDocumentsOnly();
    });
    if (enabled) unawaited(_indexGridOcr());
  }

  Future<List<DocumentRecord>> _searchGridOcr(String query) async {
    final matches = await _ocrTools.searchText(query);
    final ids = matches.map((row) => row['id'] as String).toSet();
    if (ids.isEmpty) return const <DocumentRecord>[];
    final all = await _documents.list();
    return all.where((document) => ids.contains(document.id))
        .toList(growable: false);
  }

  Future<void> _indexGridOcr() async {
    if (!mounted || !widget.ocrSearchAvailable || !_ocrSelected ||
        _ocrBusy || _searchQuery.trim().isEmpty) return;
    final run = ++_ocrEpoch;
    setState(() {
      _ocrBusy = true;
      _ocrDone = 0;
      _ocrTotal = 0;
      _ocrMessage = null;
    });
    try {
      final summary = await _ocrTools.indexPendingPdfsForSearch(
        shouldCancel: () => !mounted || !widget.ocrSearchAvailable ||
            !_ocrSelected || run != _ocrEpoch,
        onProgress: (done, total) {
          if (!mounted || run != _ocrEpoch) return;
          if (done % 10 == 0 || done == total) {
            setState(() {
              _ocrDone = done;
              _ocrTotal = total;
              _reloadDocumentsOnly();
            });
          }
        },
      );
      if (mounted && run == _ocrEpoch) {
        setState(() => _ocrMessage = summary.failed == 0
            ? 'Grid OCR search ready'
            : '${summary.failed} Grid PDFs could not be read.');
      }
    } on OcrIndexCancelled {
      // User turned off content search.
    } catch (error) {
      if (mounted && run == _ocrEpoch) {
        setState(() => _ocrMessage = 'Grid OCR unavailable: $error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _ocrBusy = false;
          _reloadDocumentsOnly();
        });
        if (run != _ocrEpoch && _ocrSelected &&
            widget.ocrSearchAvailable && _searchQuery.trim().isNotEmpty) {
          unawaited(_indexGridOcr());
        }
      }
    }
  }

  void _reloadDocumentsOnly() {
    final epoch = ++_folderLoadEpoch;
    final folderId = _currentFolderId;
    final query = _searchQuery.trim();
    _resetDocumentPages();
    // Preserve existing global search and exact custom Name/Date sort behavior.
    _pagedDocumentsMode = query.isEmpty && !_explicitSort;
    _documentsFuture = query.isNotEmpty
        ? _ocrSelected ? _searchGridOcr(query) : _documents.list(query: query)
        : _pagedDocumentsMode
            ? _getFirstPage(folderId, epoch)
            : _documents.listInFolder(folderId);
  }

  void _load() {
    _idleFolderPrefetchTimer?.cancel();
    _prefetchFolderCandidates = const [];
    _prefetchFolderEpoch = -1;
    final folderId = _currentFolderId;
    final folderFuture = _repository.childrenOf(folderId);
    _foldersFuture = folderFuture;
    _reloadDocumentsOnly();
    final epoch = _folderLoadEpoch;
    final previewRevision = _folderPreviewRevision;
    final documentFuture = _documentsFuture;
    if (_searchQuery.trim().isEmpty) {
      // A saved preview is display-only until SQLite/provider validation.
      if (!_suppressFolderPreviews.contains(FolderPreviewCache.gridKey(folderId))) {
        unawaited(_restoreFolderPreview(folderId));
      }
      unawaited(_saveVerifiedFolderPreview(
        folderId, epoch, previewRevision, folderFuture, documentFuture,
      ));
    }
  }

  Future<void> _loadMoreFolderDocuments() async {
    if (!mounted || !_pagedDocumentsMode || !_hasMoreFolderDocuments ||
        _loadingMoreFolderDocuments || _pageLoadFailed) return;
    final epoch = _folderLoadEpoch;
    final folderId = _currentFolderId;
    final name = _nextDocumentName;
    final id = _nextDocumentId;
    if (name == null || id == null) return;
    setState(() => _loadingMoreFolderDocuments = true);
    try {
      final cursor = '$epoch:$folderId:$name:$id';
      final inFlight = _nextPagePrefetchCursor == cursor
          ? _nextPagePrefetch : null;
      final page = await (inFlight != null
          ? inFlight.then<FolderDocumentPage>(
              (prefetched) => prefetched ??
                  _documents.listInFolderPage(
                    folderId,
                    pageSize: _gridPageSize,
                    afterName: name,
                    afterId: id,
                  ),
            )
          : _documents.listInFolderPage(
              folderId,
              pageSize: _gridPageSize,
              afterName: name,
              afterId: id,
            ));
      if (!mounted || epoch != _folderLoadEpoch || !_pagedDocumentsMode ||
          folderId != _currentFolderId) return;
      // The loaded page is consumed exactly once. The next cursor gets the
      // same bounded one-page look-ahead, never a bulk read.
      _nextPagePrefetch = null;
      _nextPagePrefetchCursor = null;
      final seen = _pagedDocuments.map((record) => record.id).toSet();
      final appended = page.records
          .where((record) => seen.add(record.id))
          .toList(growable: false);
      setState(() {
        _pagedDocuments = List<DocumentRecord>.unmodifiable([
          ..._pagedDocuments, ...appended,
        ]);
        _hasMoreFolderDocuments = page.hasMore;
        _nextDocumentName = page.nextName;
        _nextDocumentId = page.nextId;
      });
      _schedulePagePrefetch(epoch);
    } catch (_) {
      if (mounted && epoch == _folderLoadEpoch) {
        setState(() => _pageLoadFailed = true);
      }
    } finally {
      if (mounted && epoch == _folderLoadEpoch) {
        setState(() => _loadingMoreFolderDocuments = false);
      }
    }
  }

  void _loadNextPageOnScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.extentAfter > 1200 ||
        (notification is ScrollUpdateNotification &&
            (notification.scrollDelta ?? 0) <= 0) ||
        (notification is OverscrollNotification &&
            notification.overscroll <= 0) ||
        !_pagedDocumentsMode || !_hasMoreFolderDocuments ||
        _loadingMoreFolderDocuments || _pageLoadFailed || _morePageScheduled ||
        notification is! ScrollUpdateNotification &&
            notification is! OverscrollNotification) return;
    _morePageScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _morePageScheduled = false;
      if (mounted) unawaited(_loadMoreFolderDocuments());
    });
  }

  Future<void> _restoreFolderPreview(String? folderId) async {
    final key = FolderPreviewCache.gridKey(folderId);
    if (_allGridPreviewsInvalidating ||
        _pendingGridPreviewInvalidations.contains(key) ||
        _savedFolderPreviews.containsKey(key) ||
        _loadingFolderPreviews.contains(key) ||
        _suppressFolderPreviews.contains(key)) return;
    final revision = _folderPreviewRevision;
    _loadingFolderPreviews.add(key);
    try {
      final preview = await FolderPreviewCache.read(key);
      if (preview == null || !mounted ||
          revision != _folderPreviewRevision ||
          _allGridPreviewsInvalidating ||
          _pendingGridPreviewInvalidations.contains(key) ||
          _savedFolderPreviews.containsKey(key) ||
          _suppressFolderPreviews.contains(key)) return;
      setState(() => _rememberFolderPreview(preview));
    } finally {
      _loadingFolderPreviews.remove(key);
    }
  }

  Future<void> _saveVerifiedFolderPreview(
    String? folderId,
    int epoch,
    int previewRevision,
    Future<List<Folder>> foldersFuture,
    Future<List<DocumentRecord>> documentsFuture,
  ) async {
    try {
      final folders = await foldersFuture;
      final documents = await documentsFuture;
      if (!mounted || epoch != _folderLoadEpoch ||
          previewRevision != _folderPreviewRevision ||
          folderId != _currentFolderId ||
          _searchQuery.trim().isNotEmpty) return;
      final key = FolderPreviewCache.gridKey(folderId);
      final preview = FolderPreview(
        key: key,
        savedAt: DateTime.now().toUtc(),
        totalPdfCount: _pagedDocumentsMode
            ? _pagedTotalCount : documents.length,
        totalFolderCount: folders.length,
        items: [
          for (final folder in folders)
            FolderPreviewItem(
              name: folder.name,
              isFolder: true,
              pdfCount: folder.pdfCount,
            ),
          for (final document in documents)
            FolderPreviewItem(
              name: document.name,
              isFolder: false,
              sizeBytes: document.sizeBytes,
            ),
        ],
      );
      _rememberFolderPreview(preview);
      _suppressFolderPreviews.remove(key);
      // Optional, bounded app-private metadata: do not hold up navigation.
      unawaited(_persistVerifiedPreview(preview, previewRevision));
      _prepareChildFolderPrefetch(folders, epoch);
    } catch (_) {
      // Errors remain visible in the existing FutureBuilder error state.
    }
  }

  void _prepareChildFolderPrefetch(List<Folder> folders, int epoch) {
    _prefetchFolderCandidates = folders
        .take(_maxPrefetchChildFolders)
        .toList(growable: false);
    _prefetchFolderEpoch = epoch;
    _queueIdleFolderPrefetch();
  }

  void _queueIdleFolderPrefetch() {
    _idleFolderPrefetchTimer?.cancel();
    if (!_gridScreenForeground || _prefetchingChildFolders ||
        _prefetchFolderCandidates.isEmpty || _searchQuery.trim().isNotEmpty ||
        _isReorderingFolders || _isSelectingFolders ||
        _prefetchFolderEpoch != _folderLoadEpoch) return;
    final epoch = _prefetchFolderEpoch;
    final candidates = _prefetchFolderCandidates;
    // Debounce interaction; run no speculative SAF/provider reads during
    // an active scroll, initial navigation, or while the app is backgrounded.
    _idleFolderPrefetchTimer = Timer(const Duration(milliseconds: 650), () {
      if (!mounted || !_gridScreenForeground ||
          epoch != _folderLoadEpoch) return;
      unawaited(_prefetchChildFolderMetadata(candidates, epoch));
    });
  }

  Future<void> _prefetchChildFolderMetadata(
    List<Folder> candidates, int epoch,
  ) async {
    if (_prefetchingChildFolders || !mounted ||
        !_gridScreenForeground || epoch != _folderLoadEpoch) return;
    _prefetchingChildFolders = true;
    final previewRevision = _folderPreviewRevision;
    try {
      for (final child in candidates) {
        if (!mounted || !_gridScreenForeground ||
            epoch != _folderLoadEpoch ||
            previewRevision != _folderPreviewRevision ||
            _searchQuery.trim().isNotEmpty) return;
        final key = FolderPreviewCache.gridKey(child.id);
        if (_savedFolderPreviews.containsKey(key) ||
            _attemptedChildPrefetches.contains(key)) continue;
        // Bound retry bookkeeping as well as work/memory.
        if (_attemptedChildPrefetches.length >= 32) {
          _attemptedChildPrefetches.remove(_attemptedChildPrefetches.first);
        }
        _attemptedChildPrefetches.add(key);
        try {
          // An existing validated preview is better than replacing it with
          // a smaller speculative subset. Read at most two cache files.
          final saved = await FolderPreviewCache.read(key);
          if (!mounted || !_gridScreenForeground ||
              epoch != _folderLoadEpoch ||
              previewRevision != _folderPreviewRevision) return;
          if (saved != null) {
            _rememberFolderPreview(saved);
            continue;
          }
          // Use the existing provider validation, never bypass it to make a
          // stale folder actionable. The result remains a read-only preview.
          final subfolders = await _repository.childrenOf(
            child.id, previewLimit: 16,
          );
          if (!mounted || !_gridScreenForeground ||
              epoch != _folderLoadEpoch ||
              previewRevision != _folderPreviewRevision) return;
          final rows = await Future.wait<Object>([
            _documents.listInFolderPage(child.id, pageSize: _gridPageSize),
            _documents.countInFolder(child.id),
            _repository.countDirectChildren(child.id),
          ]);
          if (!mounted || !_gridScreenForeground ||
              epoch != _folderLoadEpoch ||
              previewRevision != _folderPreviewRevision) return;
          final page = rows[0] as FolderDocumentPage;
          final count = rows[1] as int;
          final childCount = rows[2] as int;
          final preview = FolderPreview(
            key: key,
            savedAt: DateTime.now().toUtc(),
            totalPdfCount: count,
            totalFolderCount: childCount,
            items: [
              for (final folder in subfolders)
                FolderPreviewItem(
                  name: folder.name,
                  isFolder: true,
                  pdfCount: folder.pdfCount,
                ),
              for (final document in page.records)
                FolderPreviewItem(
                  name: document.name,
                  isFolder: false,
                  sizeBytes: document.sizeBytes,
                ),
            ],
          );
          _rememberFolderPreview(preview);
          // Never block the user or alter Grid's SQLite/portable PDFs.
          unawaited(_persistVerifiedPreview(preview, previewRevision));
        } catch (_) {
          // Optional prefetch failures must not alter navigation or PDFs.
        }
      }
    } finally {
      _prefetchingChildFolders = false;
    }
  }

  Widget _savedFolderPreview(FolderPreview preview) {
    final items = preview.items;
    return Column(
      children: [
        const LinearProgressIndicator(minHeight: 2),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Row(children: [
            const Icon(Icons.history, size: 16),
            const SizedBox(width: 8),
            Expanded(child: Text(
              'Saved preview · verifying current files',
              style: Theme.of(context).textTheme.bodySmall,
            )),
          ]),
        ),
        Expanded(
          child: ListView.builder(
            key: const ValueKey('grid-folder-saved-preview'),
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 104),
            itemCount: items.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) return Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  '${preview.totalFolderCount ?? preview.folderCount} folders · ${preview.totalPdfCount ?? preview.pdfCount} PDFs (saved preview)',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              );
              final item = items[index - 1];
              return ListTile(
                key: ValueKey('saved-preview-${index - 1}'),
                leading: Icon(item.isFolder
                    ? Icons.folder_outlined : Icons.picture_as_pdf_outlined),
                title: Text(
                  item.isFolder ? item.name : '${item.name}.pdf',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(item.isFolder
                    ? '${item.pdfCount} PDFs'
                    : _size(item.sizeBytes)),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _isReorderingFolders = false;
      _draftFolderOrder = <Folder>[];
      final key = FolderPreviewCache.gridKey(_currentFolderId);
      _suppressFolderPreviews.add(key);
      _savedFolderPreviews.remove(key);
      _load();
    });
    // Wait for both sections to settle. FutureBuilder renders any errors;
    // swallowing here prevents a failed refresh from escaping the indicator.
    try {
      await Future.wait<Object?>([_foldersFuture, _documentsFuture]);
    } catch (_) {
      // The corresponding FutureBuilder displays the actionable error state.
    }
  }

  Future<void> _openFolder(Folder folder) async {
    setState(() {
      _isSelectingFolders = false;
      _selectedFolderIds.clear();
      _isSelectingDocuments = false;
      _selectedDocumentIds.clear();
      _ancestors.add(folder);
      _currentFolderId = folder.id;
      _currentTitle = folder.name;
      _load();
    });
  }

  void _goToRoot() {
    setState(() {
      _isSelectingFolders = false;
      _selectedFolderIds.clear();
      _isSelectingDocuments = false;
      _selectedDocumentIds.clear();
      _ancestors.clear();
      _currentFolderId = null;
      _currentTitle = 'Folders';
      _load();
    });
  }

  void _goToAncestor(int index) {
    setState(() {
      _isSelectingFolders = false;
      _selectedFolderIds.clear();
      _isSelectingDocuments = false;
      _selectedDocumentIds.clear();
      if (index < 0) {
        _ancestors.clear();
        _currentFolderId = null;
        _currentTitle = 'Folders';
        _load();
        return;
      }
      final folder = _ancestors[index];
      _ancestors.removeRange(index + 1, _ancestors.length);
      _currentFolderId = folder.id;
      _currentTitle = folder.name;
      _load();
    });
  }


  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<String?> _askName({String title = 'New folder', String initial = ''}) async {
    var enteredName = initial;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Folder name',
            hintText: 'e.g. Insurance',
            border: OutlineInputBorder(),
          ),
          onChanged: (value) => enteredName = value,
          onFieldSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, enteredName),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    return result?.trim();
  }

  Future<ImportDecision?> _reviewSinglePdf(
    String suggestedName,
    String? suggestedCategoryId,
    List<ImportCategoryOption> categories,
  ) async {
    final allFolders = await _repository.allFoldersWithPaths();
    if (!mounted) return null;
    var pdfName = suggestedName;
    String? destinationId = _currentFolderId;
    final result = await showDialog<ImportDecision>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, refresh) => Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: LayoutBuilder(
            builder: (dialogContext, constraints) {
              final media = MediaQuery.of(dialogContext);
              final screenAvailableHeight =
                  (media.size.height - media.viewInsets.bottom - 48)
                      .clamp(180.0, media.size.height)
                      .toDouble();
              final availableHeight = constraints.maxHeight.isFinite
                  ? (constraints.maxHeight < screenAvailableHeight
                      ? constraints.maxHeight
                      : screenAvailableHeight)
                  : screenAvailableHeight;
              return ConstrainedBox(
                constraints: BoxConstraints(maxHeight: availableHeight),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Add PDF to DocsGrid',
                        style: Theme.of(dialogContext).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 16),
                      Flexible(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextFormField(
                                initialValue: suggestedName,
                                autofocus: true,
                                onChanged: (value) => pdfName = value,
                                decoration: const InputDecoration(
                                  labelText: 'PDF name',
                                  suffixText: '.pdf',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              const SizedBox(height: 14),
                              DropdownButtonFormField<String?>(
                                initialValue: destinationId,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Destination folder',
                                  border: OutlineInputBorder(),
                                ),
                                items: [
                                  const DropdownMenuItem<String?>(
                                    value: null,
                                    child: Text('My Documents (root)'),
                                  ),
                                  for (final option in allFolders)
                                    DropdownMenuItem<String?>(
                                      value: option.folder.id,
                                      child: Text(
                                        option.path,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: (value) =>
                                    refresh(() => destinationId = value),
                              ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  icon: const Icon(Icons.create_new_folder_outlined),
                                  label: const Text('New folder'),
                                  onPressed: () async {
                                    final newName = await _askName();
                                    if (newName == null ||
                                        newName.isEmpty ||
                                        !dialogContext.mounted) {
                                      return;
                                    }
                                    try {
                                      final created = await _repository.create(
                                        name: newName,
                                        parentId: destinationId,
                                      );
                                      final updated =
                                          await _repository.allFoldersWithPaths();
                                      refresh(() {
                                        destinationId = created.id;
                                        allFolders
                                          ..clear()
                                          ..addAll(updated);
                                      });
                                    } catch (error) {
                                      if (dialogContext.mounted) {
                                        ScaffoldMessenger.of(dialogContext)
                                            .showSnackBar(
                                          SnackBar(
                                            content: Text(error.toString()),
                                          ),
                                        );
                                      }
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: const Text('Cancel'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () {
                              final name = pdfName.trim();
                              if (name.isEmpty) return;
                              Navigator.pop(
                                dialogContext,
                                ImportDecision(
                                  name: name,
                                  categoryId: suggestedCategoryId,
                                ),
                              );
                            },
                            child: const Text('Save PDF'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    if (result == null) return null;
    // The destination is captured by the dialog state and applied by the
    // repository's import transaction through this one-file review result.
    return ImportDecision(
      name: result.name,
      categoryId: result.categoryId,
      targetFolderId: destinationId,
    );
  }

  Future<void> _showFolderTree() async {
    final options = await _repository.allFoldersWithPaths();
    if (!mounted) return;
    final folders = options.map((option) => option.folder).toList(growable: false);
    final byParent = <String?, List<Folder>>{};
    for (final folder in folders) {
      byParent.putIfAbsent(folder.parentId, () => <Folder>[]).add(folder);
    }
    final expanded = <String>{};
    final selectedId = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, refresh) {
          Widget buildNode(Folder folder, int depth) {
            final children = byParent[folder.id] ?? const <Folder>[];
            final isExpanded = expanded.contains(folder.id);
            final isCurrent = folder.id == _currentFolderId;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.only(left: 12.0 + depth * 18.0, right: 12),
                  leading: Icon(children.isEmpty
                      ? Icons.folder_outlined
                      : isExpanded ? Icons.folder_open_outlined : Icons.folder_outlined),
                  title: Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  selected: isCurrent,
                  trailing: children.isEmpty ? null : IconButton(
                    tooltip: isExpanded ? 'Collapse folder' : 'Expand folder',
                    icon: Icon(isExpanded ? Icons.expand_less : Icons.expand_more),
                    onPressed: () => refresh(() {
                      if (isExpanded) {
                        expanded.remove(folder.id);
                      } else {
                        expanded.add(folder.id);
                      }
                    }),
                  ),
                  onTap: () => Navigator.pop(sheetContext, folder.id),
                ),
                if (isExpanded)
                  for (final child in children) buildNode(child, depth + 1),
              ],
            );
          }
          return SafeArea(
            child: FractionallySizedBox(
              heightFactor: 0.78,
              child: Column(
                children: [
                  const ListTile(
                    title: Text('Browse folders', style: TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('Tap a folder to open it; use arrows to expand subfolders.'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.home_outlined),
                    title: const Text('Folders (root)'),
                    selected: _currentFolderId == null,
                    onTap: () => Navigator.pop(sheetContext, ''),
                  ),
                  if (_currentFolderId != null && _ancestors.length > 1)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.arrow_upward),
                      title: Text('Up to ${_ancestors[_ancestors.length - 2].name}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.pop(
                        sheetContext, _ancestors[_ancestors.length - 2].id),
                    ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView(
                      key: const PageStorageKey('docsgrid-folder-tree'),
                      children: [
                        for (final child in byParent[_currentFolderId] ?? const <Folder>[])
                          buildNode(child, 0),
                        if ((byParent[_currentFolderId] ?? const <Folder>[]).isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: Text('No subfolders in this folder.')),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (!mounted || selectedId == null) return;
    if (selectedId.isEmpty) {
      _goToRoot();
      return;
    }
    final selected = folders.where((folder) => folder.id == selectedId).firstOrNull;
    if (selected == null) return;
    final ancestorIndex = _ancestors.indexWhere((folder) => folder.id == selectedId);
    if (ancestorIndex >= 0) {
      _goToAncestor(ancestorIndex);
    } else {
      await _openFolder(selected);
    }
  }

  Future<void> _createFolder() async {
    final name = await _askName();
    if (!mounted || name == null || name.isEmpty) return;
    final parentId = _currentFolderId;
    try {
      await _repository.create(name: name, parentId: parentId);
      if (!mounted) return;
      setState(_load);
      _message('Folder created.');
    } catch (error) {
      if (!mounted) return;
      _message(error.toString().replaceFirst('Invalid argument(s): ', ''));
    }
  }

  Future<void> _addPdf() async {
    try {
      final result = await _documents.importPdfs(
        targetFolderId: _currentFolderId,
        review: _reviewSinglePdf,
      );
      if (!mounted) return;
      await _refresh();
      if (!mounted) return;
      final details = result.errors.isEmpty ? '' : '\n${result.errors.first}';
      _message('Added ${result.added} · Duplicates ${result.duplicates} · Failed ${result.failed}$details');
    } catch (error) {
      if (mounted) _message('PDF import failed: $error');
    }
  }

  void _toggleFolderSelection(Folder folder) {
    setState(() {
      _isSelectingFolders = true;
      if (!_selectedFolderIds.add(folder.id)) _selectedFolderIds.remove(folder.id);
    });
  }

  void _startFolderSelection(Folder folder) {
    if (_isReorderingFolders) return;
    setState(() {
      _isSelectingFolders = true;
      _isSelectingDocuments = false;
      _selectedDocumentIds.clear();
      _selectedFolderIds.add(folder.id); // Long press selects immediately.
    });
  }

  void _clearFolderSelection() {
    setState(() {
      _isSelectingFolders = false;
      _selectedFolderIds.clear();
    });
  }

  Future<void> _toggleAllVisibleFolders() async {
    try {
      final folders = await _foldersFuture;
      if (!mounted || !_isSelectingFolders) return;
      final query = _searchQuery.trim().toLowerCase();
      final visibleIds = folders
          .where((folder) => query.isEmpty ||
              (!_ocrSelected && folder.name.toLowerCase().contains(query)))
          .map((folder) => folder.id)
          .toSet();
      if (visibleIds.isEmpty) return;
      setState(() {
        if (_selectedFolderIds.containsAll(visibleIds)) {
          _selectedFolderIds.removeAll(visibleIds);
        } else {
          _selectedFolderIds.addAll(visibleIds);
        }
      });
    } catch (error) {
      if (mounted) _message('Could not select all folders: $error');
    }
  }

  Future<void> _showSelectedFolderDetails() async {
    if (_selectedFolderIds.isEmpty) return;
    final ids = Set<String>.of(_selectedFolderIds);
    try {
      final details = await _repository.selectionDetails(ids);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Selection Details'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Selected folders: ${details.selectedFolderCount}'),
              const SizedBox(height: 8),
              Text('Folders inside: ${details.nestedFolderCount}'),
              const SizedBox(height: 8),
              Text('PDFs inside: ${details.pdfCount}'),
              const SizedBox(height: 8),
              Text('Total PDF size: ${_size(details.totalPdfSizeBytes)}'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) _message('Could not calculate folder details: $error');
    }
  }

  Future<void> _startFolderReorderFromMenu() async {
    try {
      final folders = await _foldersFuture;
      if (!mounted) return;
      if (folders.isEmpty) {
        _message('No folders to rearrange.');
        return;
      }
      _beginFolderReorder(folders);
    } catch (error) {
      if (mounted) _message('Could not load folders to rearrange: $error');
    }
  }

  Widget _buildFolderSelectionToolbar() {
    return FutureBuilder<List<Folder>>(
      future: _foldersFuture,
      builder: (context, snapshot) {
        final selected = (snapshot.data ?? const <Folder>[])
            .where((folder) => _selectedFolderIds.contains(folder.id))
            .toList();
        final scheme = Theme.of(context).colorScheme;
        return Material(
          key: const ValueKey('grid-folder-selection-header'),
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(22),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            child: Row(children: [
              IconButton(
                key: const ValueKey('grid-folder-select-all'),
                tooltip: 'Select all folders',
                onPressed: _toggleAllVisibleFolders,
                icon: const Icon(Icons.select_all),
                visualDensity: VisualDensity.compact,
              ),
              Expanded(
                child: Text(
                  '${_selectedFolderIds.length} selected',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                key: const ValueKey('grid-folder-move-selected'),
                tooltip: 'Move selected folders',
                onPressed: selected.isEmpty ? null : () => _moveFolders(selected),
                icon: const Icon(Icons.drive_file_move_outlined),
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                key: const ValueKey('grid-folder-delete-selected'),
                tooltip: 'Move selected folders to Recycle Bin',
                onPressed: selected.isEmpty
                    ? null : () => _deleteSelectedFolders(selected),
                icon: const Icon(Icons.delete_outline),
                visualDensity: VisualDensity.compact,
              ),
              PopupMenuButton<String>(
                key: const ValueKey('grid-folder-selected-more'),
                tooltip: 'Selection actions',
                icon: const Icon(Icons.more_vert),
                onSelected: (action) {
                  if (action == 'details') {
                    unawaited(_showSelectedFolderDetails());
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem<String>(
                    value: 'details',
                    enabled: selected.isNotEmpty,
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
      },
    );
  }

  void _beginFolderReorder(List<Folder> visibleFolders) {
    if (_isSelectingFolders || _isReorderingFolders || visibleFolders.isEmpty) return;
    setState(() {
      _searchController.clear();
      _searchQuery = '';
      _isReorderingFolders = true;
      // Custom drag order supersedes any user-selected alphabetic/date order.
      _sortRevision++;
      _explicitSort = false;
      _sortField = StorageSortField.name;
      _sortAscending = true;
      _draftFolderOrder = List<Folder>.from(visibleFolders);
      _reloadDocumentsOnly();
    });
    _saveSortPreference();
  }

  Future<void> _moveFolders(List<Folder> selected) async {
    if (selected.isEmpty) return;
    final options = await _repository.allFoldersWithPaths();
    if (!mounted) return;
    final selectedIds = selected.map((folder) => folder.id).toSet();
    final selectedPaths = options
        .where((option) => selectedIds.contains(option.folder.id))
        .map((option) => option.path)
        .toList();
    final validDestinations = options.where((option) {
      if (selectedIds.contains(option.folder.id)) return false;
      return !selectedPaths.any((path) =>
          option.path == path || option.path.startsWith('$path / '));
    }).toList();
    final destination = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Move selected folders to')),
          ListTile(
            leading: const Icon(Icons.home_outlined),
            title: const Text('Folders (root)'),
            onTap: () => Navigator.pop(ctx, ''),
          ),
          for (final option in validDestinations)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(option.path, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(ctx, option.folder.id),
            ),
        ]),
      ),
    );
    if (destination == null) return;
    try {
      await _repository.moveManyToParent(
        selected.map((folder) => folder.id).toList(),
        destination.isEmpty ? null : destination,
      );
      if (!mounted) return;
      setState(() {
        _isSelectingFolders = false;
        _selectedFolderIds.clear();
      });
      await _refresh();
      _message('Moved ${selected.length} folder(s).');
    } catch (error) {
      if (mounted) _message('Could not move folders: $error');
    }
  }

  Future<void> _deleteSelectedFolders(List<Folder> selected) async {
    if (selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move folders to Recycle Bin?'),
        content: Text(
          'The selected ${selected.length} folder(s), including their PDFs and subfolders, will be moved to Recycle Bin. Original files will be retained.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton.tonal(onPressed: () => Navigator.pop(ctx, true), child: const Text('Move to Recycle Bin')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final pdfCount = await _repository.moveManyToRecycleBin(
        selected.map((folder) => folder.id).toList(),
      );
      if (!mounted) return;
      setState(() {
        _isSelectingFolders = false;
        _selectedFolderIds.clear();
      });
      await _refresh();
      _message('Moved ${selected.length} folder(s) and $pdfCount PDF(s) to Recycle Bin.');
    } catch (error) {
      if (mounted) _message('Could not delete folders: $error');
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
    await _deleteSelectedFolders([folder]);
  }

  /// Bulk commands must address all selected PDFs, not merely the currently
  /// rendered first page. No file operation is authorized by preview metadata.
  Future<List<DocumentRecord>> _allSelectableDocuments(
    List<DocumentRecord> currentlyLoaded,
  ) async {
    if (!_pagedDocumentsMode) return currentlyLoaded;
    return _documents.listInFolder(_currentFolderId);
  }

  void _clearDocumentSelection() {
    setState(() {
      _isSelectingDocuments = false;
      _selectedDocumentIds.clear();
    });
  }

  Future<void> _selectAllDocuments(
    List<DocumentRecord> currentlyLoaded,
  ) async {
    final folderId = _currentFolderId;
    final epoch = _folderLoadEpoch;
    try {
      final all = await _allSelectableDocuments(currentlyLoaded);
      if (!mounted || !_isSelectingDocuments ||
          folderId != _currentFolderId || epoch != _folderLoadEpoch) return;
      final allIds = all.map((item) => item.id).toSet();
      if (allIds.isEmpty) return;
      setState(() {
        if (_selectedDocumentIds.containsAll(allIds)) {
          _selectedDocumentIds.removeAll(allIds);
        } else {
          _selectedDocumentIds.addAll(allIds);
        }
      });
    } catch (error) {
      if (mounted) _message('Could not select all PDFs: $error');
    }
  }

  Future<void> _showSelectedPdfDetails() async {
    if (_selectedDocumentIds.isEmpty) return;
    final folderId = _currentFolderId;
    final epoch = _folderLoadEpoch;
    final selectedIds = Set<String>.of(_selectedDocumentIds);
    try {
      final loaded = await _documentsFuture;
      final all = await _allSelectableDocuments(loaded);
      if (!mounted || epoch != _folderLoadEpoch ||
          folderId != _currentFolderId) return;
      final selected = all.where((doc) => selectedIds.contains(doc.id));
      var count = 0;
      var sizeBytes = 0;
      for (final doc in selected) {
        count++;
        if (doc.sizeBytes > 0) sizeBytes += doc.sizeBytes;
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Selection Details'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Selected PDFs: $count'),
              const SizedBox(height: 8),
              Text('Total PDF size: ${_size(sizeBytes)}'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) _message('Could not calculate PDF details: $error');
    }
  }

  Widget _buildPdfSelectionToolbar() {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<DocumentRecord>>(
      future: _documentsFuture,
      builder: (context, snapshot) {
        final loaded = snapshot.data ?? const <DocumentRecord>[];
        return Material(
          key: const ValueKey('grid-pdf-selection-header'),
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(22),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
            child: Row(children: [
              IconButton(
                key: const ValueKey('grid-pdf-select-all'),
                tooltip: 'Select all',
                onPressed: () => unawaited(_selectAllDocuments(loaded)),
                icon: const Icon(Icons.select_all),
                visualDensity: VisualDensity.compact,
              ),
              Expanded(
                child: Text(
                  '${_selectedDocumentIds.length} selected',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                key: const ValueKey('grid-pdf-share-selected'),
                tooltip: 'Share selected',
                onPressed: _selectedDocumentIds.isEmpty
                    ? null : () => unawaited(_shareSelectedDocuments(loaded)),
                icon: const Icon(Icons.share_outlined),
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                key: const ValueKey('grid-pdf-move-selected'),
                tooltip: 'Move selected to folder',
                onPressed: _selectedDocumentIds.isEmpty
                    ? null : () => _moveSelected(loaded),
                icon: const Icon(Icons.drive_file_move_outlined),
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                key: const ValueKey('grid-pdf-delete-selected'),
                tooltip: 'Move selected to Recycle Bin',
                onPressed: _selectedDocumentIds.isEmpty
                    ? null : () => unawaited(_deleteSelectedDocuments(loaded)),
                icon: const Icon(Icons.delete_outline),
                visualDensity: VisualDensity.compact,
              ),
              PopupMenuButton<String>(
                key: const ValueKey('grid-pdf-selected-more'),
                tooltip: 'PDF selection actions',
                icon: const Icon(Icons.more_vert),
                onSelected: (action) {
                  if (action == 'details') {
                    unawaited(_showSelectedPdfDetails());
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem<String>(
                    value: 'details',
                    enabled: _selectedDocumentIds.isNotEmpty,
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
      },
    );
  }

  Future<void> _deleteSelectedDocuments(
    List<DocumentRecord> currentlyLoaded,
  ) async {
    final folderId = _currentFolderId;
    final epoch = _folderLoadEpoch;
    final all = await _allSelectableDocuments(currentlyLoaded);
    if (!mounted || epoch != _folderLoadEpoch ||
        folderId != _currentFolderId) return;
    final selected = all.where((d) => _selectedDocumentIds.contains(d.id))
        .toList();
    if (selected.isEmpty) return;
    await _documents.moveManyToTrash(selected);
    if (!mounted) return;
    _clearDocumentSelection();
    await _refresh();
  }

  Future<void> _shareSelectedDocuments(
    List<DocumentRecord> currentlyLoaded,
  ) async {
    final folderId = _currentFolderId;
    final epoch = _folderLoadEpoch;
    final all = await _allSelectableDocuments(currentlyLoaded);
    if (!mounted || epoch != _folderLoadEpoch ||
        folderId != _currentFolderId) return;
    final selected = all.where(
      (item) => _selectedDocumentIds.contains(item.id),
    ).toList(growable: false);
    if (selected.isEmpty) return;
    await DocumentToolsService().shareManyStoredPdfs(
      selected.map((item) => item.storagePath).toList(growable: false),
      selected.map((item) => '${item.name}.pdf').toList(growable: false),
    );
  }

  Future<void> _moveSelected(List<DocumentRecord> currentlyLoaded) async {
    final folderId = _currentFolderId;
    final epoch = _folderLoadEpoch;
    final all = await _allSelectableDocuments(currentlyLoaded);
    if (!mounted || epoch != _folderLoadEpoch ||
        folderId != _currentFolderId) return;
    final selected = all.where((d) => _selectedDocumentIds.contains(d.id)).toList();
    if (selected.isEmpty) return;
    final folders = await _repository.allFoldersWithPaths();
    if (!mounted) return;
    final destination = await showModalBottomSheet<String>(
      context: context, showDragHandle: true,
      builder: (ctx) => SafeArea(child: ListView(shrinkWrap: true, children: [
        const ListTile(title: Text('Move selected PDFs to')),
        ListTile(leading: const Icon(Icons.home_outlined), title: const Text('My Documents (root)'), onTap: () => Navigator.pop(ctx, '')),
        for (final folder in folders)
          ListTile(leading: const Icon(Icons.folder_outlined), title: Text(folder.path), onTap: () => Navigator.pop(ctx, folder.folder.id)),
      ])),
    );
    if (destination == null) return;
    final result = await _documents.moveManyToFolder(selected, destination.isEmpty ? null : destination);
    if (!mounted) return;
    _clearDocumentSelection();
    await _refresh();
    final failures = result['failures'] as List<String>;
    _message('Moved ${result['moved']} PDF(s). ${failures.length} failed.');
  }

  Future<void> _addReminder(DocumentRecord document) async {
    final title = TextEditingController(text: 'Reminder - ${document.name}');
    final note = TextEditingController();
    var selected = DateTime.now().add(const Duration(days: 1));
    final saved = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(
      builder: (ctx, refresh) => AlertDialog(
        scrollable: true, title: const Text('Add to reminder'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, decoration: const InputDecoration(labelText: 'Reminder title')),
          TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'Note (optional)')),
          ListTile(contentPadding: EdgeInsets.zero, title: const Text('Date & time'),
            subtitle: Text('${selected.day.toString().padLeft(2, '0')}/${selected.month.toString().padLeft(2, '0')}/${selected.year} · ${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}'),
            onTap: () async {
              final date = await showDatePicker(context: ctx, initialDate: selected, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 3650)));
              if (date == null || !ctx.mounted) return;
              final time = await showTimePicker(context: ctx, initialTime: TimeOfDay.fromDateTime(selected));
              if (time != null) refresh(() => selected = DateTime(date.year, date.month, date.day, time.hour, time.minute));
            }),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () { if (title.text.trim().isNotEmpty && selected.isAfter(DateTime.now())) Navigator.pop(ctx, true); }, child: const Text('Save')),
        ],
      ),
    ));
    await WidgetsBinding.instance.endOfFrame;
    final reminderTitle = title.text.trim();
    final reminderNote = note.text.trim();
    title.dispose(); note.dispose();
    if (saved != true) return;
    await ReminderRepository().create(title: reminderTitle, note: reminderNote, remindAt: selected, documentId: document.id);
    if (mounted) _message('Reminder saved for this PDF.');
  }

  Future<void> _chooseCategory(DocumentRecord document) async {
    final categories = await _categories.listCategories();
    if (!mounted) return;
    final selected = await showDialog<String?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Set category'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Uncategorised')),
          for (final category in categories)
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, category.id), child: Text(category.name)),
        ],
      ),
    );
    if (selected == null) return;
    await _categories.setDocumentCategory(document.id, selected.isEmpty ? null : selected);
    await _refresh();
  }

  Future<void> _editTags(DocumentRecord document) async {
    final tags = await _categories.listTags();
    final current = await _categories.tagsForDocument(document.id);
    if (!mounted) return;
    final selected = current.map((tag) => tag.id).toSet();
    final result = await showDialog<Set<String>>(context: context, builder: (ctx) => StatefulBuilder(
      builder: (ctx, refresh) => AlertDialog(
        title: const Text('Edit tags'),
        content: SizedBox(width: 360, child: tags.isEmpty
          ? const Text('Create tags in Category & Tag settings first.')
          : Column(mainAxisSize: MainAxisSize.min, children: [
              for (final tag in tags)
                CheckboxListTile(dense: true, contentPadding: EdgeInsets.zero, value: selected.contains(tag.id),
                  title: Text(tag.name), onChanged: (value) => refresh(() {
                    if (value == true) { selected.add(tag.id); } else { selected.remove(tag.id); }
                  })),
            ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, selected), child: const Text('Save tags')),
        ],
      ),
    ));
    if (result == null) return;
    await _categories.setDocumentTags(document.id, result.toList());
    await _refresh();
  }

  Future<void> _renamePdf(DocumentRecord document) async {
    final controller = TextEditingController(text: document.name);
    final value = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Rename PDF'),
      content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'File name', suffixText: '.pdf')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
      ],
    ));
    await WidgetsBinding.instance.endOfFrame;
    controller.dispose();
    if (value == null) return;
    await _documents.rename(document, value);
    await _refresh();
  }

  Future<void> _moveOne(DocumentRecord document) async {
    final folders = await _repository.allFoldersWithPaths();
    if (!mounted) return;
    final destination = await showModalBottomSheet<String>(
      context: context, showDragHandle: true,
      builder: (ctx) => SafeArea(child: ListView(shrinkWrap: true, children: [
        const ListTile(title: Text('Move PDF to folder')),
        ListTile(leading: const Icon(Icons.home_outlined), title: const Text('My Documents (root)'), onTap: () => Navigator.pop(ctx, '')),
        for (final folder in folders)
          ListTile(leading: const Icon(Icons.folder_outlined), title: Text(folder.path), onTap: () => Navigator.pop(ctx, folder.folder.id)),
      ])),
    );
    if (destination == null) return;
    await _documents.moveToFolder(document, destination.isEmpty ? null : destination);
    await _refresh();
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // Grid and List share the same data, selection state, and action handlers.
  // Both sliver builders remain lazy: no full-list widget or PDF prefetch.
  Widget _folderActions(Folder folder) => PopupMenuButton<String>(
        tooltip: 'Folder actions',
        onSelected: (value) {
          if (value == 'rename') _renameFolder(folder);
          if (value == 'move') _moveFolders([folder]);
          if (value == 'delete') _deleteFolder(folder);
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(value: 'move', child: Text('Move')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      );

  Widget _buildGridFolderCard(Folder folder, int index) {
    final selected = _selectedFolderIds.contains(folder.id);
    final scheme = Theme.of(context).colorScheme;
    final tiled = _showGridTiles && !_isReorderingFolders;
    Widget checkbox() => Checkbox(
          value: selected,
          onChanged: (_) => _toggleFolderSelection(folder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
          ),
        );
    Widget folderIcon({double diameter = 56}) => Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFC9D4FF) : const Color(0xFFE2E7FF),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.folder_outlined,
            color: const Color(0xFF405582),
            size: tiled ? 36 : 30,
          ),
        );

    return Card(
      key: ValueKey('folder-${folder.id}'),
      margin: EdgeInsets.symmetric(vertical: tiled ? 4 : 8, horizontal: tiled ? 4 : 0),
      elevation: 0,
      color: selected ? const Color(0xFFDDE4FF) : scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(26),
        side: BorderSide(
          color: selected
              ? const Color(0xFF687BC6)
              : scheme.outlineVariant.withValues(alpha: 0.55),
          width: selected ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(26),
        onTap: _isSelectingFolders
            ? () => _toggleFolderSelection(folder)
            : _isReorderingFolders ? null : () => _openFolder(folder),
        onLongPress: _isReorderingFolders
            ? null : () => _startFolderSelection(folder),
        child: tiled
            ? Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 48,
                      child: Row(children: [
                        if (_isSelectingFolders) checkbox(),
                        const Spacer(),
                        if (!_isSelectingFolders) _folderActions(folder),
                      ]),
                    ),
                    Expanded(child: Center(child: folderIcon(diameter: 58))),
                    Text(
                      folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Folder · ${folder.pdfCount} PDFs',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              )
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(children: [
                  if (_isSelectingFolders) ...[
                    SizedBox(width: 40, child: checkbox()),
                    const SizedBox(width: 10),
                  ],
                  folderIcon(),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          folder.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Folder · ${folder.pdfCount} PDFs',
                          style: TextStyle(
                            fontSize: 15,
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_isSelectingFolders)
                    const SizedBox.shrink()
                  else if (_isReorderingFolders)
                    ReorderableDelayedDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: Icon(Icons.drag_indicator, color: Colors.grey),
                      ),
                    )
                  else
                    _folderActions(folder),
                ]),
              ),
      ),
    );
  }

  void _toggleDocumentSelection(DocumentRecord document) {
    setState(() {
      _isSelectingDocuments = true;
      if (!_selectedDocumentIds.add(document.id)) {
        _selectedDocumentIds.remove(document.id);
      }
    });
  }

  void _onDocumentLongPress(DocumentRecord document) {
    if (_isSelectingFolders || _isReorderingFolders) return;
    setState(() {
      _isSelectingDocuments = true;
      _selectedDocumentIds.add(document.id);
    });
  }

  Future<void> _onDocumentTap(DocumentRecord document) async {
    if (_isSelectingFolders) return;
    if (_isSelectingDocuments) {
      _toggleDocumentSelection(document);
      return;
    }
    try {
      await StorageLocationService.instance.openPdf(
        document.storagePath, gridPdf: true,
      );
      await _documents.markOpened(document);
    } catch (error) {
      if (mounted) _message('Could not open PDF: $error');
    }
  }

  Widget _pdfActions(DocumentRecord document) => PopupMenuButton<String>(
        tooltip: 'PDF actions',
        onSelected: (action) async {
          try {
            if (action == 'share') {
              await DocumentToolsService().shareStoredPdf(
                document.storagePath, '${document.name}.pdf',
              );
            }
            if (action == 'favorite') {
              await _documents.setFavorite(document, !document.isFavorite);
            }
            if (action == 'category') await _chooseCategory(document);
            if (action == 'tags') await _editTags(document);
            if (action == 'rename') await _renamePdf(document);
            if (action == 'move') await _moveOne(document);
            if (action == 'reminder') await _addReminder(document);
            if (action == 'trash') await _documents.moveToTrash(document);
            if (mounted) await _refresh();
          } catch (error) {
            if (mounted) _message('Action failed: $error');
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'share', child: Text('Share PDF')),
          PopupMenuItem(value: 'favorite',
              child: Text(document.isFavorite ? 'Remove from Star' : 'Add to Star')),
          const PopupMenuItem(value: 'category', child: Text('Set category')),
          const PopupMenuItem(value: 'tags', child: Text('Edit tags')),
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
          const PopupMenuItem(value: 'move', child: Text('Move to folder')),
          const PopupMenuItem(value: 'reminder', child: Text('Add to reminder')),
          const PopupMenuItem(value: 'trash', child: Text('Move to Recycle Bin')),
        ],
      );

  Widget _buildGridPdfCard(DocumentRecord document) {
    final selected = _selectedDocumentIds.contains(document.id);
    Widget checkbox() => Checkbox(
          value: selected,
          onChanged: (_) => _toggleDocumentSelection(document),
        );
    Widget thumbnail() => DocumentThumbnail(
          documentId: document.id,
          storagePath: document.storagePath,
          sizeBytes: document.sizeBytes,
        );
    return Card(
      key: ValueKey('grid-pdf-${document.id}'),
      margin: const EdgeInsets.all(4),
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: _showGridTiles
          ? InkWell(
              onTap: () => unawaited(_onDocumentTap(document)),
              onLongPress: () => _onDocumentLongPress(document),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 48,
                      child: Row(children: [
                        if (_isSelectingDocuments) checkbox(),
                        const Spacer(),
                        if (!_isSelectingDocuments) _pdfActions(document),
                      ]),
                    ),
                    Expanded(child: Center(child: thumbnail())),
                    Text(
                      '${document.name}.pdf',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _size(document.sizeBytes),
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            )
          : ListTile(
              leading: _isSelectingDocuments ? checkbox() : thumbnail(),
              title: Text('${document.name}.pdf',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(_size(document.sizeBytes)),
              onLongPress: () => _onDocumentLongPress(document),
              onTap: () => unawaited(_onDocumentTap(document)),
              trailing: _isSelectingDocuments ? null : _pdfActions(document),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: PopScope(
      canPop: !_isSelectingFolders &&
          !_isSelectingDocuments && _ancestors.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_isSelectingFolders) {
          _clearFolderSelection();
        } else if (_isSelectingDocuments) {
          _clearDocumentSelection();
        } else if (_ancestors.isNotEmpty) {
          _goToAncestor(_ancestors.length - 2);
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Selection keeps this entire normal header row hidden; its
        // actions now float above the bottom tab navigation instead.
        if (!keyboardVisible &&
            !_isSelectingFolders && !_isSelectingDocuments)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: _showFolderTree,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(children: [
                              Flexible(
                                child: Text(
                                  _currentTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Icon(Icons.arrow_drop_down, size: 24),
                            ]),
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        key: const ValueKey('grid-folder-normal-more'),
                        tooltip: 'Grid folder options',
                        icon: const Icon(Icons.more_vert),
                        onSelected: (action) {
                          if (action == 'rearrange') {
                            unawaited(_startFolderReorderFromMenu());
                          } else if (action == 'settings') {
                            widget.onOpenSettings?.call();
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem<String>(
                            value: 'rearrange',
                            enabled: !_isReorderingFolders,
                            child: const ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.swap_vert),
                              title: Text('Rearrange'),
                            ),
                          ),
                          PopupMenuItem<String>(
                            value: 'settings',
                            enabled: widget.onOpenSettings != null,
                            child: const ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.settings_outlined),
                              title: Text('Settings'),
                            ),
                          ),
                        ],
                      ),
                      IconButton(
                        key: const ValueKey('grid-view-mode-toggle'),
                        tooltip: _showGridTiles ? 'List view' : 'Grid view',
                        onPressed: _isReorderingFolders ? null : _toggleGridListView,
                        icon: Icon(_showGridTiles
                            ? Icons.view_list_outlined : Icons.grid_view_outlined),
                      ),
                      IconButton(
                        tooltip: 'Create folder',
                        onPressed: _createFolder,
                        icon: const Icon(Icons.create_new_folder_outlined),
                      ),
                    ],
                  ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(12, keyboardVisible ? 2 : 8, 12, keyboardVisible ? 2 : 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                      if (value.trim().isEmpty) _ocrEpoch++;
                      _reloadDocumentsOnly();
                    });
                    if (_ocrSelected && value.trim().isNotEmpty) {
                      unawaited(_indexGridOcr());
                    }
                  },
                  decoration: InputDecoration(
                    hintText: _ocrSelected
                        ? 'Search text inside Grid PDFs'
                        : 'Search folders or PDF names',
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
                        if (_searchQuery.isNotEmpty)
                          IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(() {
                              _searchController.clear();
                              _searchQuery = '';
                              _ocrEpoch++;
                              _reloadDocumentsOnly();
                            }),
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
                enabled: !_isReorderingFolders,
                onFieldChanged: (field) => _changeSort(field: field),
                onAscendingChanged: (value) => _changeSort(ascending: value),
              ),
            ],
          ),
        ),
        if (widget.ocrSearchAvailable && _ocrSelected)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_ocrBusy)
                  LinearProgressIndicator(
                    value: _ocrTotal == 0 ? null : _ocrDone / _ocrTotal,
                    minHeight: 2,
                  ),
                Text(_ocrBusy
                    ? 'Indexing Grid PDF text locally: $_ocrDone / $_ocrTotal'
                    : _ocrMessage ??
                        'Enter a term to search text inside Grid PDFs.',
                  style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        if (_ancestors.isNotEmpty && !keyboardVisible)
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
            builder: (context, folderSnapshot) {
              if (folderSnapshot.connectionState == ConnectionState.waiting) {
                final preview = _searchQuery.trim().isEmpty
                    ? _savedFolderPreviews[FolderPreviewCache.gridKey(_currentFolderId)]
                    : null;
                return preview != null
                    ? _savedFolderPreview(preview)
                    : const Center(child: CircularProgressIndicator());
              }
              if (folderSnapshot.hasError) {
                return Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.error_outline, size: 40),
                    const SizedBox(height: 8),
                    const Text('Could not load folders.'),
                    TextButton(onPressed: _refresh, child: const Text('Try again')),
                  ]),
                );
              }
              final folders = folderSnapshot.data ?? const <Folder>[];
              return FutureBuilder<List<DocumentRecord>>(
                future: _documentsFuture,
                builder: (context, documentSnapshot) {
                  if (documentSnapshot.connectionState == ConnectionState.waiting) {
                    final preview = _searchQuery.trim().isEmpty
                        ? _savedFolderPreviews[FolderPreviewCache.gridKey(_currentFolderId)]
                        : null;
                    return preview != null
                        ? _savedFolderPreview(preview)
                        : const Center(child: CircularProgressIndicator());
                  }
                  if (documentSnapshot.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.error_outline, size: 40),
                            const SizedBox(height: 8),
                            const Text('Could not load PDFs.'),
                            const SizedBox(height: 4),
                            Text(
                              '${documentSnapshot.error}',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            FilledButton.icon(
                              onPressed: _refresh,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Try again'),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  final documents = _pagedDocumentsMode
                      ? _pagedDocuments
                      : documentSnapshot.data ?? const <DocumentRecord>[];
                  final query = _searchQuery.trim().toLowerCase();
                  final folderSource = _isReorderingFolders ? _draftFolderOrder : folders;
                  final displayedFolders = folderSource
                      .where((folder) => query.isEmpty ||
                          (!_ocrSelected && folder.name.toLowerCase().contains(query)))
                      .toList(growable: true);
                  final displayedDocuments = documents
                      .where((document) => query.isEmpty || _ocrSelected ||
                          document.name.toLowerCase().contains(query))
                      .toList(growable: true);
                  if (_explicitSort && !_isReorderingFolders) {
                    displayedFolders.sort((a, b) => compareStorageItems(
                      nameA: a.name,
                      nameB: b.name,
                      dateA: a.updatedAt,
                      dateB: b.updatedAt,
                      field: _sortField,
                      ascending: _sortAscending,
                    ));
                    displayedDocuments.sort((a, b) => compareStorageItems(
                      nameA: a.name,
                      nameB: b.name,
                      dateA: a.updatedAt ?? a.createdAt,
                      dateB: b.updatedAt ?? b.createdAt,
                      field: _sortField,
                      ascending: _sortAscending,
                    ));
                  }
                  if (folders.isEmpty && documents.isEmpty &&
                      (!_pagedDocumentsMode || _pagedTotalCount == 0) &&
                      query.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.folder_open_outlined, size: 52),
                          const SizedBox(height: 12),
                          Text(
                            _currentFolderId == null
                                ? 'All Your Docs. One Smart Place.'
                                : 'This folder is empty',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _currentFolderId == null
                                ? 'Organize with folders, categories & tags.\n'
                                    'Find faster, avoid duplicates & share easily.'
                                : 'Create a folder or import a PDF to get started.',
                            textAlign: TextAlign.center,
                          ),
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
                  return NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      if (notification.depth == 0) {
                        if (notification is ScrollStartNotification) {
                          _idleFolderPrefetchTimer?.cancel();
                        } else if (notification is ScrollEndNotification) {
                          _queueIdleFolderPrefetch();
                        }
                      }
                      _loadNextPageOnScroll(notification);
                      return false; // Keep pull-to-refresh and scrolling intact.
                    },
                    child: RefreshIndicator(
                      onRefresh: _refresh,
                      child: CustomScrollView(
                        cacheExtent: 360,
                        key: ValueKey('grid-folder-list-${_currentFolderId ?? '__root__'}-$_folderLoadEpoch'),
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                              child: Text(
                                '${folders.length} folders · ${_pagedDocumentsMode ? _pagedTotalCount : documents.length} PDFs',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ),
                          if (query.isNotEmpty &&
                              displayedFolders.isEmpty && displayedDocuments.isEmpty)
                            const SliverToBoxAdapter(
                              child: Padding(
                                padding: EdgeInsets.all(28),
                                child: Center(child: Text('No matching folders or PDFs.')),
                              ),
                            ),
                          if (displayedFolders.isNotEmpty) ...[
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                                child: Text('FOLDERS',
                                    style: Theme.of(context).textTheme.labelLarge),
                              ),
                            ),
                            if (_isReorderingFolders)
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  child: ReorderableListView.builder(
                                    shrinkWrap: true,
                                    physics: const NeverScrollableScrollPhysics(),
                                    buildDefaultDragHandles: false,
                                    itemCount: displayedFolders.length,
                                    onReorderItem: (oldIndex, newIndex) {
                                      setState(() {
                                        final moved = _draftFolderOrder.removeAt(oldIndex);
                                        _draftFolderOrder.insert(newIndex, moved);
                                      });
                                    },
                                    itemBuilder: (context, index) =>
                                        _buildGridFolderCard(
                                          displayedFolders[index], index),
                                  ),
                                ),
                              )
                            else if (_showGridTiles)
                              SliverPadding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                sliver: SliverGrid.builder(
                                  key: const ValueKey('grid-folder-tiles'),
                                  itemCount: displayedFolders.length,
                                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 220,
                                    mainAxisExtent: 192,
                                    mainAxisSpacing: 8,
                                    crossAxisSpacing: 8,
                                  ),
                                  itemBuilder: (context, index) =>
                                      _buildGridFolderCard(
                                        displayedFolders[index], index),
                                ),
                              )
                            else
                              SliverPadding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                sliver: SliverList.builder(
                                  key: const ValueKey('grid-folder-rows'),
                                  itemCount: displayedFolders.length,
                                  itemBuilder: (context, index) =>
                                      _buildGridFolderCard(
                                        displayedFolders[index], index),
                                ),
                              ),
                          ],
                          if (displayedDocuments.isNotEmpty) ...[
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
                                child: Text('PDF DOCUMENTS',
                                    style: Theme.of(context).textTheme.labelLarge),
                              ),
                            ),
                            SliverPadding(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              sliver: _showGridTiles
                                  ? SliverGrid.builder(
                                      key: const ValueKey('grid-pdf-tiles'),
                                      itemCount: displayedDocuments.length,
                                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                        maxCrossAxisExtent: 220,
                                        mainAxisExtent: 192,
                                        mainAxisSpacing: 8,
                                        crossAxisSpacing: 8,
                                      ),
                                      itemBuilder: (context, index) =>
                                          _buildGridPdfCard(displayedDocuments[index]),
                                    )
                                  : SliverList.builder(
                                      key: const ValueKey('grid-pdf-rows'),
                                      itemCount: displayedDocuments.length,
                                      itemBuilder: (context, index) =>
                                          _buildGridPdfCard(displayedDocuments[index]),
                                    ),
                            ),
                          ],
                          if (_pagedDocumentsMode &&
                              (_hasMoreFolderDocuments ||
                                  _loadingMoreFolderDocuments || _pageLoadFailed))
                            SliverToBoxAdapter(
                              child: Padding(
                                key: const ValueKey('grid-folder-next-page'),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                child: Center(
                                  child: _loadingMoreFolderDocuments
                                      ? const CircularProgressIndicator()
                                      : TextButton.icon(
                                          icon: Icon(_pageLoadFailed
                                              ? Icons.refresh : Icons.expand_more),
                                          label: Text(_pageLoadFailed
                                              ? 'Retry loading more PDFs'
                                              : 'Load more PDFs'),
                                          onPressed: () {
                                            if (_pageLoadFailed) {
                                              setState(() => _pageLoadFailed = false);
                                            }
                                            unawaited(_loadMoreFolderDocuments());
                                          },
                                        ),
                                ),
                              ),
                            ),
                          const SliverToBoxAdapter(
                            child: SizedBox(height: 104),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        if (_isReorderingFolders && !keyboardVisible)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const ValueKey('finish-folder-reorder'),
                  icon: const Icon(Icons.check),
                  label: const Text('Finish'),
                  onPressed: () async {
                    try {
                      await _repository.reorderChildren(
                        _currentFolderId,
                        _draftFolderOrder.map((folder) => folder.id).toList(),
                      );
                      if (!mounted) return;
                      setState(() => _isReorderingFolders = false);
                      await _refresh();
                      _message('Folder order saved.');
                    } catch (error) {
                      if (mounted) _message('Could not save folder order: $error');
                    }
                  },
                ),
              ),
            ),
          ),
      ],
          ),
          if (!keyboardVisible &&
              (_isSelectingFolders || _isSelectingDocuments))
            Positioned(
              key: const ValueKey('grid-floating-selection-position'),
              left: 12,
              right: 12,
              bottom: 12,
              child: SafeArea(
                top: false,
                child: _isSelectingFolders
                    ? _buildFolderSelectionToolbar()
                    : _buildPdfSelectionToolbar(),
              ),
            ),
          if (!keyboardVisible &&
              !_isReorderingFolders &&
              !_isSelectingFolders &&
              !_isSelectingDocuments)
            Positioned(
              right: 18,
              bottom: 18,
              child: FloatingActionButton(
                tooltip: 'Add PDF',
                onPressed: _addPdf,
                child: const Icon(Icons.picture_as_pdf_outlined),
              ),
            ),
        ],
      ),
      ),
    );
  }
}
