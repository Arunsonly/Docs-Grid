import 'pdf_details_dialog.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/document_repository.dart';
import '../data/home_dashboard_cache.dart';
import '../data/grid_recent_history.dart';
import '../data/phone_recent_history.dart';
import '../data/phone_pdf_move_service.dart';
import '../data/phone_pdf_delta.dart';
import '../data/phone_refresh_queue.dart';
import '../data/phone_star_repository.dart';
import '../data/phone_portable_state.dart';
import '../data/phone_trash_origin.dart';
import '../../../core/storage/storage_location_service.dart';
import '../../../core/storage/grid_storage_boundary.dart';
import '../../../core/storage/portable_snapshot_events.dart';
import '../../categories/data/category_repository.dart';
import '../../folders/data/folder_repository.dart';
import '../../tools/document_tools_service.dart';
import 'document_thumbnail.dart';
import 'phone_storage_browser_screen.dart';
import 'recycle_bin_dialog.dart';
import 'phone_move_folder_picker.dart';
import '../../folders/presentation/folders_screen.dart';
import '../../reminders/data/reminder_repository.dart';
import '../../../core/diagnostics/startup_timeline.dart';

class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key, this.favoritesOnly = false, this.recentOnly = false,
    this.phoneOnly = false,
    this.active = true, this.onBackAtRoot});
  final bool favoritesOnly;
  final bool recentOnly;
  final bool phoneOnly;
  /// Offstage tabs retain their state, but must not intercept Back or poll storage.
  final bool active;
  final VoidCallback? onBackAtRoot;

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen>
    with WidgetsBindingObserver {
  bool get _isStartupHome =>
      !widget.phoneOnly && !widget.favoritesOnly && !widget.recentOnly;
  final _repository = DocumentRepository();
  final _homeCache = HomeDashboardCache();
  GridStorageBoundary _gridBoundary = GridStorageBoundary();
  final _categoryRepository = CategoryRepository();
  final _folderRepository = FolderRepository();
  final _tools = DocumentToolsService();
  final _search = TextEditingController();
  final _scrollController = ScrollController();
  List<DocumentRecord> _documents = [];
  bool _loading = true;
  final bool _importing = false;
  bool _gridView = false;
  // Home search tabs are view state only. Neither storage index is mutated.
  bool _homeSearchPhoneSelected = true;
  static const int _homePhoneSearchPageSize = 40;
  int _homePhoneSearchVisibleCount = _homePhoneSearchPageSize;
  int _totalStorageBytes = 0;
  int _totalDocumentCount = 0;
  bool _liveHomeSummaryLoaded = false;
  bool _showCachedHomeSummary = false;
  bool _liveGridRecentLoaded = false;
  List<String> _cachedGridRecentNames = const [];
  int _starredCount = 0;
  int? _phoneStorageBytes;
  bool? _phoneHasAllFilesAccess;
  bool _phoneScanLoading = false;
  bool _phoneScanCompleted = false;
  StreamSubscription<StorageChangeNotice>? _storageChangesSubscription;
  Timer? _phoneRefreshDebounce;
  bool _phoneScanPending = false;
  bool _phonePatchInFlight = false;
  bool _phoneRefreshAfterBusy = false;
  bool _phoneMediaStoreReady = false;
  final PhoneRefreshQueue _phoneChangeQueue = PhoneRefreshQueue();
  StreamSubscription<void>? _libraryChangesSubscription;
  Timer? _libraryRefreshDebounce;
  bool _libraryRefreshPendingWhileHidden = false;
  bool _phoneRefreshPendingWhileHidden = false;
  List<Map<String, String>> _phoneLastRoots = const [];
  Map<String, Object?> _phoneLastMediaVolumes = const {};
  int _trashCount = 0;
  int _trashFolderCount = 0;
  List<Map<String, Object?>> _phoneRecent = [];
  List<DocumentRecord> _gridRecent = [];
  int _recentLoadGeneration = 0;
  bool _showStarredRecent = false;
  List<DocumentRecord> _starredRecent = [];
  List<Map<String, Object?>> _phoneStarred = [];
  final Set<String> _phoneStarredUris = <String>{};
  String _recentFilter = 'grid';
  // Separate from Recent so switching views preserves each selected source.
  String _starredFilter = 'phone';
  List<Map<String, Object?>> _phoneEntries = [];
  final Set<String> _selectedIds = <String>{};
  bool _selectionMode = false;
  int _loadGeneration = 0;
  Timer? _searchDebounce;
  String? _error;
  DocumentPageCursor? _nextCursor;
  bool _hasMore = false;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    if (_isStartupHome) StartupTimeline.mark('home_init');
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadPhoneStarred());
    _storageChangesSubscription =
        StorageLocationService.instance.storageChanges.listen(
      (notice) => _schedulePhoneStorageRefresh(notice),
      onError: (_) {
        // Provider change events are best-effort; resume reconciliation remains.
      },
    );
    if (!widget.phoneOnly) {
      // Display last-known *non-actionable* Home metadata while SQLite
      // independently loads the authoritative data. Never block first paint.
      if (!widget.favoritesOnly && !widget.recentOnly) {
        unawaited(_restoreCachedHomeSnapshot());
      }
      _load();
      _loadViewPreference();
      _loadTrashSummary();
      _loadRecentDocuments();
      _libraryChangesSubscription = PortableSnapshotEvents.changes.listen((_) {
        _scheduleLibraryRefresh();
      });
    }
    _search.addListener(_onSearchChanged);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isStartupHome) StartupTimeline.mark('home_first_frame');
      if (widget.phoneOnly) {
        // Show the Phone tab in place; do not push a second page after scanning.
        _scanPhoneStorage(openBrowser: false);
      } else if (!widget.favoritesOnly && !widget.recentOnly) {
        _scanPhoneStorage(openBrowser: false);
      }
    });
  }

  @override
  void didUpdateWidget(covariant DocumentsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active &&
        _phoneRefreshPendingWhileHidden) {
      _phoneRefreshPendingWhileHidden = false;
      _queuePhoneChangeRefresh();
    }
    if (!oldWidget.active && widget.active &&
        _libraryRefreshPendingWhileHidden) {
      _libraryRefreshPendingWhileHidden = false;
      _scheduleLibraryRefresh();
    }
  }


  Future<void> _restoreCachedHomeSnapshot() async {
    if (_isStartupHome) StartupTimeline.mark('home_cache_read_start');
    final summaryFuture = _homeCache.readSummary();
    final namesFuture = _homeCache.readRecentNames();
    final summary = await summaryFuture;
    final names = await namesFuture;
    if (_isStartupHome) {
      StartupTimeline.mark('home_cache_read_done');
      StartupTimeline.mark(summary == null
          ? 'home_cache_summary_miss' : 'home_cache_summary_hit');
    }
    if (!mounted || widget.phoneOnly || widget.favoritesOnly ||
        widget.recentOnly) return;
    // Live database values always supersede optional cached placeholders.
    if ((_liveHomeSummaryLoaded || summary == null) &&
        (_liveGridRecentLoaded || names.isEmpty)) return;
    setState(() {
      if (!_liveHomeSummaryLoaded && summary != null) {
        _totalDocumentCount = summary.documentCount;
        _starredCount = summary.favoriteCount;
        _totalStorageBytes = summary.totalBytes;
        _showCachedHomeSummary = true;
        if (_isStartupHome) StartupTimeline.mark('home_cache_summary_applied');
      }
      if (!_liveGridRecentLoaded) _cachedGridRecentNames = names;
    });
  }

  Future<void> _loadViewPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool('docsgrid_document_grid_view_v1') ?? false;
      if (mounted) setState(() => _gridView = saved);
    } catch (_) {
      // View preference is optional; default to the compact list.
    }
  }

  Future<void> _toggleDocumentView() async {
    final next = !_gridView;
    setState(() => _gridView = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('docsgrid_document_grid_view_v1', next);
    } catch (_) {
      // Keep the in-memory selection even if preference storage is unavailable.
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _loadingMore || !_hasMore) return;
    // Phone-result scrolling must not fetch unrelated Grid pages.
    if (!widget.favoritesOnly && !widget.recentOnly &&
        _search.text.trim().isNotEmpty && _homeSearchPhoneSelected) return;
    if (_scrollController.position.extentAfter < 600) _loadMore();
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 280), () {
      if (!mounted) return;
      _homePhoneSearchVisibleCount = _homePhoneSearchPageSize;
      _load();
    });
  }

  void _scheduleLibraryRefresh() {
    if (!mounted || widget.phoneOnly || widget.favoritesOnly ||
        widget.recentOnly) return;
    if (!widget.active) {
      _libraryRefreshPendingWhileHidden = true;
      return;
    }
    _libraryRefreshDebounce?.cancel();
    _libraryRefreshDebounce = Timer(const Duration(milliseconds: 240), () {
      if (!mounted) return;
      if (!widget.active) {
        _libraryRefreshPendingWhileHidden = true;
        return;
      }
      unawaited(_load());
      unawaited(_loadRecentDocuments());
      unawaited(_loadTrashSummary());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _schedulePhoneStorageRefresh();
    }
  }

  void _schedulePhoneStorageRefresh([StorageChangeNotice? notice]) {
    if (!mounted || widget.favoritesOnly || widget.recentOnly) return;
    _phoneChangeQueue.add(notice);
    if (!widget.active) {
      _phoneRefreshPendingWhileHidden = true;
      return;
    }
    _queuePhoneChangeRefresh();
  }

  void _queuePhoneChangeRefresh() {
    if (!mounted || !_phoneChangeQueue.hasPending) return;
    _phoneRefreshDebounce?.cancel();
    _phoneRefreshDebounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted) unawaited(_refreshPhoneStorageFromChanges());
    });
  }

  Future<void> _refreshPhoneStorageFromChanges() async {
    if (!mounted) return;
    if (_phoneScanLoading || _phonePatchInFlight) {
      // Do not convert a precise event into an unconditional full scan just
      // because another query has the Phone index temporarily busy.
      _phoneRefreshAfterBusy = true;
      return;
    }
    final batch = _phoneChangeQueue.take();
    if (!batch.hasChanges) return;
    final requiresFull = batch.requiresFullRefresh || !_phoneMediaStoreReady ||
        !_phoneScanCompleted || _phoneLastRoots.isEmpty;
    if (requiresFull) {
      await _scanPhoneStorage(openBrowser: false);
      return;
    }
    final changedUris = batch.mediaUris;
    final changedPaths = batch.paths;

    _phonePatchInFlight = true;
    try {
      final storage = StorageLocationService.instance;
      if (!Platform.isAndroid || !await storage.hasAllFilesAccess()) {
        await _scanPhoneStorage(openBrowser: false);
        return;
      }
      final change = await storage.queryPhonePdfChanges(
        mediaUris: changedUris,
        paths: changedPaths,
      );
      if (change['complete'] != true) {
        await _scanPhoneStorage(openBrowser: false);
        return;
      }
      final observedVolumes = Map<String, Object?>.from(
        change['volumes'] as Map,
      );
      final mountedVolumes = change['mountedVolumes'] as List<String>;
      if (!PhonePdfDelta.volumesAreCompatible(
        previous: _phoneLastMediaVolumes,
        observed: observedVolumes,
        mounted: mountedVolumes,
      )) {
        await _scanPhoneStorage(openBrowser: false);
        return;
      }
      final updated = change['entries'] as List<Map<String, Object?>>;
      final patch = PhonePdfDelta.apply(
        existing: _gridBoundary.filterEntries(_phoneEntries),
        updates: _gridBoundary.filterEntries(updated),
        touchedMediaUris: change['touchedMediaUris'] as List<String>,
        touchedLocalPaths: change['touchedLocalPaths'] as List<String>,
      );
      if (!mounted) return;
      _phoneLastMediaVolumes = {
        ..._phoneLastMediaVolumes,
        ...observedVolumes,
      };
      if (!patch.changed &&
          patch.entries.length == _phoneEntries.length) return;
      setState(() => _phoneEntries = patch.entries);
      // This is a proven complete MediaStore baseline plus scoped changes,
      // not a partial scan; keep Recent discovery and the saved cache in sync.
      final scopes = <String, List<Map<String, Object?>>>{
        for (final volume in _phoneLastMediaVolumes.keys)
          'media:$volume': <Map<String, Object?>>[],
      };
      for (final item in patch.entries) {
        final volume = item['volumeName'] as String?;
        if (volume != null && item['isDirectory'] != true) {
          scopes['media:$volume']?.add(item);
        }
      }
      try {
        if (scopes.isNotEmpty) {
          await PhoneRecentHistory.observeCompletedScans(scopes);
          if (mounted && !widget.phoneOnly) await _loadRecentDocuments();
        }
      } catch (_) {
        // Recent shortcuts are optional and never block the Phone index.
      }
      await _persistPhoneStorageIndexCache(
        _phoneLastRoots, patch.entries,
        mediaStoreVolumes: _phoneLastMediaVolumes,
      );
    } catch (_) {
      // Permission change, provider timeout or ambiguous delta: use the
      // established safe full index, never infer that PDFs were deleted.
      if (mounted) await _scanPhoneStorage(openBrowser: false);
    } finally {
      _phonePatchInFlight = false;
      if (mounted && (_phoneRefreshAfterBusy || _phoneChangeQueue.hasPending)) {
        _phoneRefreshAfterBusy = false;
        // Preserve the exact queued URI/path hints; do not call the no-arg
        // scheduler, which deliberately requests a full resume scan.
        _queuePhoneChangeRefresh();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _storageChangesSubscription?.cancel();
    _libraryChangesSubscription?.cancel();
    _libraryRefreshDebounce?.cancel();
    _phoneRefreshDebounce?.cancel();
    _loadGeneration++;
    _searchDebounce?.cancel();
    _search.removeListener(_onSearchChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_isStartupHome) StartupTimeline.mark('home_page_start');
    final generation = ++_loadGeneration;
    if (mounted) setState(() { _loading = true; _loadingMore = false; });
    // Run the small first page and dashboard aggregates concurrently. Render
    // the document rows as soon as the page is ready; never make the first
    // useful screen wait for a full-library summary query.
    if (_isStartupHome) StartupTimeline.mark('home_summary_start');
    final summaryFuture = _repository.dashboardSummary();
    try {
      final page = await _repository.listPage(
        query: _search.text,
        favoritesOnly: widget.favoritesOnly,
        recentOnly: widget.recentOnly,
        pageSize: 40,
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _documents = page.items;
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore;
        _loading = false;
        _error = null;
      });
      if (_isStartupHome) StartupTimeline.mark('home_page_ready');
      // Summary is secondary UI. Update it when ready without delaying the
      // first page, and ignore stale completions after a newer refresh.
      try {
        final summary = await summaryFuture;
        if (!mounted || generation != _loadGeneration) return;
        setState(() {
          _totalStorageBytes = summary.totalBytes;
          _totalDocumentCount = summary.documentCount;
          _starredCount = summary.favoriteCount;
          _liveHomeSummaryLoaded = true;
          _showCachedHomeSummary = false;
        });
        if (_isStartupHome) StartupTimeline.mark('home_summary_ready');
        if (!widget.phoneOnly && !widget.favoritesOnly && !widget.recentOnly) {
          unawaited(_homeCache.saveSummary(
            documentCount: summary.documentCount,
            favoriteCount: summary.favoriteCount,
            totalBytes: summary.totalBytes,
          ));
        }
      } catch (_) {
        if (_isStartupHome) StartupTimeline.mark('home_summary_failed');
        // A summary failure must not blank a successfully loaded PDF list.
      }
    } catch (error) {
      if (_isStartupHome) StartupTimeline.mark('home_page_failed');
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _loadMore() async {
    final cursor = _nextCursor;
    if (cursor == null || !_hasMore || _loadingMore || _loading) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _repository.listPage(
        query: _search.text,
        favoritesOnly: widget.favoritesOnly,
        recentOnly: widget.recentOnly,
        pageSize: 40,
        cursor: cursor,
      );
      if (!mounted) return;
      setState(() {
        final known = _documents.map((document) => document.id).toSet();
        _documents.addAll(page.items.where((document) => !known.contains(document.id)));
        _nextCursor = page.nextCursor;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      _message('Could not load more documents: $error');
    }
  }

  Future<void> _patchDocument(String id, {bool removeIfMissing = true}) async {
    final updated = await _repository.getById(id);
    if (!mounted) return;
    setState(() {
      final index = _documents.indexWhere((item) => item.id == id);
      if (updated == null) {
        if (removeIfMissing && index >= 0) _documents.removeAt(index);
        return;
      }
      if (index >= 0) {
        _documents[index] = updated;
      } else if (_search.text.trim().isEmpty ||
          updated.name.toLowerCase().contains(_search.text.trim().toLowerCase())) {
        _documents.add(updated);
      }
      _documents.sort((a, b) {
        final aOpened = a.lastOpenedAt;
        final bOpened = b.lastOpenedAt;
        if (aOpened != null && bOpened == null) return -1;
        if (aOpened == null && bOpened != null) return 1;
        final recent = (bOpened ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(aOpened ?? DateTime.fromMillisecondsSinceEpoch(0));
        if (recent != 0) return recent;
        final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        return byName != 0 ? byName : a.id.compareTo(b.id);
      });
    });
  }

  Future<void> _loadTrashSummary() async {
    if (_isStartupHome) StartupTimeline.mark('home_trash_start');
    try {
      final values = await Future.wait<Object>([
        _repository.trashCount(),
        _folderRepository.listTrashFolderRoots(),
      ]);
      final count = values[0] as int;
      final folders = values[1] as List<Map<String, Object?>>;
      if (!mounted) return;
      setState(() {
        _trashCount = count;
        _trashFolderCount = folders.length;
      });
      if (_isStartupHome) StartupTimeline.mark('home_trash_ready');
    } catch (_) {
      // Keep the dashboard usable; the Recycle Bin screen reports its own error.
    }
  }

  Future<void> _refreshDashboardSummary() async {
    if (widget.favoritesOnly || widget.recentOnly) return;
    final summary = await _repository.dashboardSummary();
    if (!mounted) return;
    setState(() {
      _totalStorageBytes = summary.totalBytes;
      _totalDocumentCount = summary.documentCount;
      _starredCount = summary.favoriteCount;
      _liveHomeSummaryLoaded = true;
      _showCachedHomeSummary = false;
    });
    if (!widget.phoneOnly) {
      unawaited(_homeCache.saveSummary(
        documentCount: summary.documentCount,
        favoriteCount: summary.favoriteCount,
        totalBytes: summary.totalBytes,
      ));
    }
    await _loadTrashSummary();
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirmMoveToRecycleBin({
    required int count,
    required String details,
  }) async {
    if (!mounted || count < 1) return false;
    final noun = count == 1 ? 'file' : 'files';
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('Move $count $noun to recycle bin?'),
            content: Text(details),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Move to recycle bin'),
              ),
            ],
          ),
        ) ==
        true;
  }

  Future<void> _browsePhoneStorage() async {
    // The Phone tab owns an inline browser. A refresh never navigates away.
    if (widget.phoneOnly) {
      await _scanPhoneStorage(openBrowser: true);
      return;
    }
    // iOS has no Android-style whole-phone scan. Ask for a Files folder
    // explicitly when the user opens Phone from Home for the first time.
    if (Platform.isIOS && _phoneLastRoots.isEmpty) {
      final picked =
          await StorageLocationService.instance.choosePhoneFolder();
      if (picked == null) return;
      await _scanPhoneStorage(openBrowser: true);
      return;
    }
    // Reuse the dashboard's completed scan. Opening its detailed browser must
    // not walk the whole storage tree a second time.
    if (_phoneScanCompleted) {
      await _showRecursiveStoragePdfs(
          Platform.isIOS ? 'Files' : 'Internal Storage', _phoneEntries);
      return;
    }
    await _scanPhoneStorage(openBrowser: true);
  }

  Future<bool> _restorePhoneStorageIndexCache(
      List<Map<String, String>> roots, GridStorageBoundary boundary) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? raw = prefs.getString('docsgrid_phone_storage_index_v1');
      if (raw == null) {
        // SharedPreferences is only the fast app-local copy. A portable
        // FolderIndex cache survives reinstall and is still refreshed live.
        try {
          final locations = await StorageLocationService.instance
              .portableDataLocationsIfAvailable();
          final folderIndexUri = locations['folderIndexUri'];
          if (folderIndexUri != null) {
            final fileUri = await StorageLocationService.instance.findChildUri(
              parentUri: folderIndexUri,
              name: 'phone_storage_index.json',
            );
            raw = await StorageLocationService.instance.readTextFile(fileUri);
          }
        } catch (_) {
          // No previous portable index is a normal first-install condition.
        }
      }
      if (raw == null) return false;
      final decoded = jsonDecode(raw);
      final signature = roots.map((root) => root['uri']!).join('|');
      if (decoded is! Map || decoded['rootSignature'] != signature ||
          decoded['gridRootSignature'] != boundary.signature ||
          decoded['entries'] is! List) return false;
      // The cache is scoped to the currently granted roots; make that
      // signature available to per-folder previews before the live scan ends.
      _phoneLastRoots = roots;
      final cached = boundary.filterEntries(
          (decoded['entries'] as List).whereType<Map>()
              .map((entry) => Map<String, Object?>.from(entry)));
      if (!mounted) return false;
      setState(() { _phoneEntries = cached; _phoneScanCompleted = true; });
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _persistPhoneStorageIndexCache(
    List<Map<String, String>> roots,
    List<Map<String, Object?>> entries, {
    Map<String, Object?> mediaStoreVolumes = const <String, Object?>{},
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = jsonEncode({
        'rootSignature': roots.map((root) => root['uri']!).join('|'),
        'gridRootSignature': _gridBoundary.signature,
        'mediaStoreVolumes': mediaStoreVolumes,
        'entries': _gridBoundary.filterEntries(entries),
        'cachedAtUtc': DateTime.now().toUtc().toIso8601String(),
      });
      await prefs.setString('docsgrid_phone_storage_index_v1', payload);
      try {
        final locations = await StorageLocationService.instance
            .portableDataLocationsIfAvailable();
        final folderIndexUri = locations['folderIndexUri'];
        if (folderIndexUri != null) {
          await StorageLocationService.instance.writeTextFile(
            parentUri: folderIndexUri,
            name: 'phone_storage_index.json',
            contents: payload,
          );
        }
      } catch (_) {
        // The app-local cache still makes the current installation fast.
      }
    } catch (_) {
      // Optional cache; never compromise the live filesystem listing.
    }
  }


  /// Store the real, granted Phone root before deleting the file. A
  /// MediaStore item URI does not identify a writable parent directory.
  Future<PhoneTrashOrigin> _phoneTrashOriginFor(
      String uri, String name) async {
    final matching = <Map<String, Object?>>[
      ..._phoneEntries.where((entry) =>
          entry['isDirectory'] != true && entry['uri'] == uri),
      ..._phoneRecent.where((entry) => entry['uri'] == uri),
    ];
    if (matching.isEmpty) {
      throw StateError('Original Phone folder is unknown. PDF was not deleted.');
    }
    final entry = matching.first;
    final parsed = Uri.tryParse(uri);
    final volume = entry['volumeName'] as String? ??
        ((parsed?.authority == 'media' &&
                parsed!.pathSegments.isNotEmpty)
            ? parsed.pathSegments.first
            : null);
    final roots = await StorageLocationService.instance.accessibleStorageRoots();
    final originalFolder = (entry['folderPath'] ?? entry['path']) as String?;
    final root = PhoneTrashOrigin.selectGrantedRoot(
      sourceUri: uri, folderPath: originalFolder ?? '',
      roots: roots, volumeName: volume,
    );
    if (root == null) {
      throw StateError(
        'Original Phone storage is not accessible. '
        'Grant the original location before deleting this PDF.',
      );
    }
    // MediaStore uses an empty relative path for PDFs directly in a storage
    // volume. That is the root folder, not an unknown destination.
    final rootLabel = roots.firstWhere(
      (candidate) => candidate['uri'] == root,
      orElse: () => const <String, String>{},
    )['name'];
    final folder = originalFolder != null && originalFolder.isNotEmpty
        ? originalFolder
        : parsed?.authority == 'media' && volume == 'external_primary'
            ? 'Internal'
            : rootLabel;
    if (folder == null || folder.isEmpty) {
      throw StateError('Original Phone folder is unavailable. PDF was kept.');
    }
    final origin = PhoneTrashOrigin(
      sourceUri: uri,
      folderPath: folder,
      rootUri: root,
      displayName: name,
      volumeName: volume,
    );
    if (!origin.localSourceMatchesRoot()) {
      throw StateError('Original Phone folder does not match its granted root.');
    }
    origin.relativeFolders; // Reject any unsafe folder path.
    return origin;
  }

  Future<void> _includeRecycledPhoneFolders(
      List<Map<String, Object?>> entries) async {
    final held = await _repository.phoneTrashFolderEntries();
    for (final folder in held) {
      final path = folder['path'];
      final existing = entries.where((entry) =>
          entry['isDirectory'] == true && entry['path'] == path);
      if (existing.isEmpty) {
        entries.add(folder);
      } else {
        final entry = existing.first;
        entry['isPending'] = true;
        entry['trashPdfCount'] = folder['trashPdfCount'];
      }
    }
  }

  Future<void> _scanPhoneStorage({required bool openBrowser}) async {
    final storage = StorageLocationService.instance;
    if (_phoneScanLoading) {
      _phoneScanPending = true;
      return;
    }
    if (_isStartupHome) StartupTimeline.mark('home_phone_scan_start');
    _phoneMediaStoreReady = false;
    if (mounted) setState(() { _phoneScanLoading = true; _phoneScanCompleted = false; });
    try {
      // Always resolve the currently selected Grid root before exposing cached
      // or freshly indexed Phone files. This does not move or delete PDFs.
      final boundary = await storage.gridStorageBoundary();
      _gridBoundary = boundary;
      var hasAllFilesAccess = false;
      if (Platform.isAndroid) {
        try {
          // The OS permission is the source of truth. StatFs may fail
          // independently and must never be interpreted as permission denial.
          hasAllFilesAccess = await storage.hasAllFilesAccess();
          if (mounted) {
            setState(() => _phoneHasAllFilesAccess = hasAllFilesAccess);
          }
        } catch (_) {
          if (mounted) setState(() => _phoneHasAllFilesAccess = null);
        }
        if (hasAllFilesAccess) {
          try {
            final usage = await storage.phoneStorageUsage();
            if (mounted) setState(() => _phoneStorageBytes = usage['usedBytes']);
          } catch (_) {
            // Storage size is supplementary; granted access remains granted.
          }
        }
      }
      if (Platform.isAndroid && !hasAllFilesAccess) {
        final granted = await storage.accessibleStorageRoots();
        if (granted.isEmpty) {
          if (mounted) setState(() {
            _phoneEntries = [];
            _phoneScanCompleted = false;
          });
          if (openBrowser && mounted) {
            await storage.requestAllFilesAccess();
            _message('Grant Android storage access or a SAF location. No folder picker was opened.');
          }
          return;
        }
      }
      var roots = await storage.accessibleStorageRoots();
      if (roots.isEmpty && Platform.isIOS && widget.phoneOnly &&
          widget.active) {
        // Apple Files access is folder-scoped, not a whole-device index.
        // Browsing must not replace the separately selected Grid root.
        final chosen = await storage.choosePhoneFolder();
        if (chosen != null) {
          roots = await storage.accessibleStorageRoots();
        }
      }
      if (roots.isEmpty) {
        if (mounted) setState(() {
          _phoneEntries = [];
          _phoneScanCompleted = true;
        });
        return;
      }

      // The cached tree is rendered immediately. MediaStore then supplies a
      // fast current index for shared volumes, including removable volumes.
      final cacheRestored =
          await _restorePhoneStorageIndexCache(roots, boundary);
      var mediaStoreComplete = false;
      var mediaStoreVolumes = <String, Object?>{};
      final entries = <Map<String, Object?>>[];
      final seen = <String>{};
      final completedRootScans = <String, List<Map<String, Object?>>>{};

      if (Platform.isAndroid && hasAllFilesAccess) {
        try {
          final index = await storage.queryPhonePdfIndex();
          final indexed = boundary.filterEntries(
              index['entries'] as List<Map<String, Object?>>);
          final complete = index['complete'] == true;
          if (complete) {
            mediaStoreComplete = true;
            mediaStoreVolumes =
                Map<String, Object?>.from(index['volumes'] as Map);
            entries.addAll(indexed);
            final completeVolumes = <String, List<Map<String, Object?>>>{
              for (final volume in mediaStoreVolumes.keys)
                'media:$volume': <Map<String, Object?>>[],
            };
            for (final item in indexed) {
              final uri = item['uri'] as String? ?? '';
              if (uri.isNotEmpty) seen.add(uri);
              final volume = item['volumeName'] as String?;
              if (volume != null) {
                completeVolumes['media:$volume']?.add(item);
              }
            }
            // Baseline the first complete scan; later scans add newly seen
            // external PDFs to Phone Recent, without importing their bytes.
            try {
              await PhoneRecentHistory.observeCompletedScans(completeVolumes);
              // Another mounted Phone tab may have recorded this scan first.
              // Always refresh the Home panel after a completed scan.
              if (mounted && !widget.phoneOnly) {
                await _loadRecentDocuments();
              }
            } catch (_) {
              // An optional Recent-list failure never interrupts Phone browsing.
            }
            // Only a complete, permission-authorized MediaStore index can
            // prove a media URI is absent. Never prune on partial scans.
            try {
              final removed = await PhoneRecentHistory.pruneAbsentMediaStoreUris(
                seen, scannedVolumes: mediaStoreVolumes.keys.toSet(),
              );
              if (removed > 0 && mounted) await _loadRecentDocuments();
            } catch (_) {
              // Recent metadata is optional; user PDFs and scan remain intact.
            }
            if (mounted) setState(() {
              _phoneEntries = List<Map<String, Object?>>.from(entries);
              _phoneScanCompleted = true;
            });
          }
        } catch (_) {
          // Unsupported provider/API falls back to the bounded SAF/file scan.
        }
      }

      if (!mediaStoreComplete) {
        // First-run provisional view: only root-level PDFs, never unverified
        // parent directories which may contain documents only in descendants.
        final firstLevelEntries = <Map<String, Object?>>[];
        for (var index = 0; index < roots.length; index++) {
          final root = roots[index];
          final label = Platform.isAndroid && index == 0
              ? 'Internal' : root['name']!;
          try {
            final children = await storage.listDirectory(root['uri']!);
            for (final child in children) {
              final name = child['name'] as String;
              if (child['isDirectory'] != true &&
                  name.toLowerCase().endsWith('.pdf')) {
                firstLevelEntries.add({
                  ...child,
                  'path': label,
                  'folderPath': label,
                });
              }
            }
          } catch (error) {
            firstLevelEntries.add({
              'name': label,
              'uri': root['uri']!,
              'folderPath': '',
              'path': label,
              'isDirectory': true,
              'isInaccessible': true,
              'accessError': error.toString(),
            });
          }
        }
        if (!mounted) return;
        if (!cacheRestored) {
          setState(() => _phoneEntries =
              boundary.filterEntries(firstLevelEntries));
        }
      }

      var inaccessibleRoots = 0;
      for (var index = 0; index < roots.length; index++) {
        final root = roots[index];
        final uri = root['uri']!;
        // MediaStore already covers local shared volumes. Keep recursive
        // traversal only for user-granted SAF/cloud roots, or as a fallback
        // when MediaStore could not produce a complete index.
        if (mediaStoreComplete && uri.startsWith('file://')) continue;
        if (!mediaStoreComplete && uri.startsWith('file://') &&
            Platform.isAndroid && hasAllFilesAccess) {
          // Native file-tree recursion is the safe fallback for failed volumes.
        }
        final label = Platform.isAndroid && index == 0
            ? 'Internal' : root['name']!;
        try {
          final found = await storage.listStorageTreeRecursively(
            uri,
            rootLabel: label,
            includeEmptyFolders: false,
            excludeGrid: boundary,
          );
          // Only successfully scanned, entirely accessible SAF/file roots
          // may advance the discovery baseline. Otherwise a permission change
          // could make old PDFs look newly added on the following scan.
          if (!found.any((item) =>
              item['isInaccessible'] == true ||
              item['isInaccessibleSummary'] == true)) {
            completedRootScans['root:$uri'] = found
                .where((item) => item['isDirectory'] != true)
                .toList(growable: false);
          }
          for (final item in found) {
            if (boundary.isManagedEntry(item,
                scanRootUri: uri, rootLabel: label)) continue;
            final itemUri = item['uri'] as String? ?? '';
            if (item['isDirectory'] != true &&
                itemUri.isNotEmpty &&
                !seen.add(itemUri)) continue;
            entries.add(item);
          }
        } catch (error) {
          inaccessibleRoots++;
          entries.add({
            'name': label,
            'uri': uri,
            'folderPath': '',
            'path': label,
            'isDirectory': true,
            'isInaccessible': true,
            'accessError': error.toString(),
          });
        }
      }
      if (!mounted) return;
      if (completedRootScans.isNotEmpty) {
        try {
          await PhoneRecentHistory.observeCompletedScans(completedRootScans);
          if (mounted && !widget.phoneOnly) {
            await _loadRecentDocuments();
          }
        } catch (_) {
          // Optional Phone Recent must never interfere with file browsing.
        }
      }
      // Ordinary scans intentionally suppress PDF-empty folders. Recycle Bin
      // placeholders keep the original location visible while archived.
      try { await _includeRecycledPhoneFolders(entries); } catch (_) {
        // Live Phone browsing must survive optional metadata failures.
      }
      if (mediaStoreVolumes.isNotEmpty) {
        await _persistPhoneStorageIndexCache(
          roots,
          entries,
          mediaStoreVolumes: mediaStoreVolumes,
        );
      } else {
        await _persistPhoneStorageIndexCache(roots, entries);
      }
      _phoneMediaStoreReady = mediaStoreComplete;
      _phoneLastMediaVolumes = mediaStoreVolumes;
      _phoneLastRoots = roots;
      setState(() {
        _phoneEntries=boundary.filterEntries(entries);
        _phoneScanCompleted = true;
      });
      if (openBrowser && !widget.phoneOnly) {
        await _showRecursiveStoragePdfs(
            Platform.isIOS ? 'Files' : 'Internal Storage',
            boundary.filterEntries(entries));
      }
      if(inaccessibleRoots>0 && mounted) _message('$inaccessibleRoots granted location(s) could not be read; they were not marked empty.');
    } catch(error) {
      if (mounted) {
        // An index-refresh failure must not erase the last usable listing.
        // Opening a cached PDF still goes through the real storage provider.
        setState(() => _phoneScanCompleted = _phoneEntries.isNotEmpty);
        _message('Phone Storage refresh failed; the last index is still shown: $error');
      }
    } finally {
      if (_isStartupHome) StartupTimeline.mark('home_phone_scan_finished');
      if (mounted) setState(() => _phoneScanLoading = false);
      if (mounted) {
        if (_phoneScanPending) {
          _phoneScanPending = false;
          // A second explicit scan request is still a real full refresh.
          _phoneChangeQueue.add(null);
        }
        if (_phoneRefreshAfterBusy || _phoneChangeQueue.hasPending) {
          _phoneRefreshAfterBusy = false;
          _queuePhoneChangeRefresh();
        }
      }
    }
  }

  Future<void> _showRecursiveStoragePdfs(String rootName, List<Map<String, Object?>> entries, {String initialPath = ''}) async {
    if (!mounted) return;
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => PhoneStorageBrowserScreen(
        rootName: rootName, entries: entries, onOpenPdf: _openExternalStoragePdf,
        onMovePdf: _movePhonePdfToGrid,
        onMoveWithinPhone: _movePhonePdfWithinPhone,
        onRenamePdf: _renamePhonePdf,
        onSharePdf: _sharePhonePdf,
        onShareSelectedPdfs: _sharePhoneSelectedPdfs,
        onMoveSelectedWithinPhone: _movePhoneSelectedWithinPhone,
        onTrashSelectedPdfs: _trashPhoneSelectedPdfs,
        onToggleStarPdf: _recordExternalFavorite,
        starredUris: _phoneStarredUris,
        onTrashPdf: _trashPhonePdf,
        initialPath: initialPath,
        cacheScope: '${_phoneLastRoots.map((root) => root['uri'] ?? '').join('|')}'
            '|grid:${_gridBoundary.signature}',
      ),
    ));
  }

  Future<void> _loadPhoneStarred() async {
    try {
      final boundary =
          await StorageLocationService.instance.gridStorageBoundary();
      final items = boundary.filterEntries(await PhoneStarRepository.list());
      if (mounted) {
        setState(() {
          _phoneStarred = items;
          // Keep the same Set reference: an independently pushed Phone
          // browser reads it when reopening its menu after a Star action.
          _phoneStarredUris
            ..clear()
            ..addAll(items.where((item) => item['needsRelinking'] != true)
                .map((item) => item['uri'] as String));
        });
      }
    } catch (_) {
      // Star metadata is optional; it must never block Phone Storage.
    }
  }

  Future<void> _loadAllStarred() async {
    try {
      final items = await _repository.listAllStarred();
      if (mounted) setState(() => _starredRecent = items);
      await _loadPhoneStarred();
    } catch (error) {
      if (mounted) _message('Could not load Starred PDFs: $error');
    }
  }

  Future<void> _clearRecentActivity() async {
    // Capture the cutoff before clearing so PDFs created/opened afterwards
    // can appear in Recent, without deleting the PDFs themselves.
    final cutoff = DateTime.now().toUtc();
    ++_recentLoadGeneration; // An older async read must not refill Recent.
    try {
      await PhoneRecentHistory.clearRecent();
      await _repository.clearOpenedHistory();
      await GridRecentHistory.markCleared(cutoff);
      await _homeCache.saveRecentNames(const []);
      if (!mounted) return;
      setState(() {
        _phoneRecent = [];
        _gridRecent = [];
        _cachedGridRecentNames = const [];
        _liveGridRecentLoaded = true;
      });
      await _loadRecentDocuments();
      if (_showStarredRecent) await _loadAllStarred();
      // Deliberately no success Snackbar for either Phone or Grid Recent.
    } catch (error) {
      if (mounted) _message('Could not clear Recent: $error');
    }
  }

  Future<List<DocumentRecord>> _loadAllRecentGrid() async {
    // Use the same durable cutoff in the full Recent picker and Home panel.
    final since = await GridRecentHistory.lastClearedAt();
    return _repository.recentActivity(limit: 100, since: since);
  }

  List<PopupMenuEntry<String>> _phoneRecentMenu(Map<String, Object?> item) => [
    const PopupMenuItem(value: 'share', child: Text('Share PDF')),
    PopupMenuItem(
      value: 'favorite',
      child: Text(_phoneStarredUris.contains(item['uri'])
          ? 'Remove from Star' : 'Add to Star'),
    ),
    const PopupMenuItem(value: 'rename', child: Text('Rename')),
    const PopupMenuItem(value: 'move_phone', child: Text('Move')),
    const PopupMenuItem(value: 'move', child: Text('Move to Grid')),
    const PopupMenuItem(value: 'trash', child: Text('Delete')),
    const PopupMenuItem(value: 'location', child: Text('File Location')),
    const PopupMenuItem(value: 'details', child: Text('Details')),
  ];

  Future<void> _handlePhoneRecentAction(Map<String, Object?> item, String action) async {
    final uri = item['uri'] as String? ?? '';
    final name = item['name'] as String? ?? 'PDF';
    if (action == 'share') {
      await _sharePhonePdf(uri, name);
    } else if (action == 'move') {
      await _movePhonePdfToGrid(uri, name);
    } else if (action == 'move_phone') {
      await _movePhonePdfWithinPhone(uri, name);
    } else if (action == 'favorite') {
      await _recordExternalFavorite(uri, name);
    } else if (action == 'trash') {
      await _trashPhonePdf(uri, name);
    } else if (action == 'rename') {
      await _renamePhonePdf(uri, name);
      await _loadRecentDocuments();
    } else if (action == 'details') {
      final matches = _phoneEntries.where((row) => row['uri'] == uri);
      await PdfDetailsDialog.showPhone(context, {...item, if (matches.isNotEmpty) ...matches.first});
    } else if (action == 'location') {
      await _showPhoneFileLocation(uri, name);
    }
  }

  Future<void> _showPhoneFileLocation(String uri, String name) async {
    final matching = <Map<String, Object?>>[
      ..._phoneEntries.where((item) => item['uri'] == uri),
      ..._phoneStarred.where((item) => item['uri'] == uri),
      ..._phoneRecent.where((item) => item['uri'] == uri),
    ];
    final rawPath = matching.isEmpty
        ? '' : (matching.first['folderPath'] ?? matching.first['path'] ?? '').toString();
    final path = rawPath.replaceAll(String.fromCharCode(92), '/').trim();
    if (!mounted) return;
    final showFolder = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('File Location'),
        content: SelectableText(path.isEmpty
            ? 'Folder location unavailable for $name.' : path),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Close'),
          ),
          if (path.isNotEmpty)
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Open folder'),
            ),
        ],
      ),
    );
    if (showFolder == true && mounted) {
      await _showRecursiveStoragePdfs(
        'Internal Storage', _phoneEntries, initialPath: path,
      );
    }
  }

  Future<void> _recordExternalFavorite(String uri, String name) async {
    try {
      final matching = <Map<String, Object?>>[
        ..._phoneEntries.where((entry) => entry['uri'] == uri),
        ..._phoneRecent.where((entry) => entry['uri'] == uri),
      ];
      final entry = matching.isEmpty ? null : matching.first;
      await PhoneStarRepository.toggle(
        uri: uri,
        name: name,
        folderPath: (entry?['folderPath'] ?? entry?['path']) as String?,
        sizeBytes: (entry?['sizeBytes'] as num?)?.toInt() ?? 0,
      );
      await _loadPhoneStarred();
      if (_showStarredRecent) await _loadAllStarred();
    } catch (error) {
      if (mounted) _message('Could not update Phone Star: $error');
    }
  }

  Future<bool> _movePhoneRecentSelectionToTrash(
    List<Map<String, Object?>> chosen,
  ) async {
    final confirmed = await _confirmMoveToRecycleBin(
      count: chosen.length,
      details: 'The selected Phone PDFs will be archived in DocsGrid Recycle Bin. Each Phone original is removed only after its archive is verified.',
    );
    if (!confirmed) return false;

    final movedUris = <String>{};
    var failed = 0;
    for (final item in chosen) {
      final uri = item['uri'] as String? ?? '';
      final name = item['name'] as String? ?? 'PDF';
      try {
        final origin = await _phoneTrashOriginFor(uri, name);
        final moved = await _repository.moveExternalPdfToTrash(
          sourceUri: uri,
          displayName: name,
          origin: origin,
        );
        if (moved) {
          movedUris.add(uri);
        } else {
          failed++;
        }
      } catch (_) {
        failed++;
      }
    }

    if (movedUris.isNotEmpty) {
      for (final uri in movedUris) {
        try { await PhoneStarRepository.remove(uri); } catch (_) {}
      }
      await _loadPhoneStarred();
      final keep = _phoneRecent
          .where((item) => !movedUris.contains(item['uri']))
          .toList(growable: false);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'docsgrid_phone_recent_v1',
        keep.map(jsonEncode).toList(),
      );
      if (mounted) setState(() => _phoneRecent = keep);
      await _scanPhoneStorage(openBrowser: false);
      await _loadTrashSummary();
      await _refreshDashboardSummary();
    }
    if (mounted && failed > 0) {
      _message('$failed Phone PDFs were kept because they could not be archived.');
    }
    return movedUris.isNotEmpty;
  }

  Future<void> _openPhoneRecentSelection(Map<String, Object?> first) async {
    final items = _phoneRecent;
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => _PhoneRecentSelectionScreen(
        items: items,
        initialUri: first['uri'] as String,
        onOpen: (item) => _openExternalStoragePdf(
          item['uri'] as String, item['name'] as String? ?? 'PDF',
        ),
        onShare: (chosen) => _tools.shareManyStoredPdfs(
          chosen.map((x) => x['uri'] as String).toList(),
          chosen.map((x) => '${x['name']}.pdf').toList(),
        ),
        onDelete: _movePhoneRecentSelectionToTrash,
      ),
    ));
  }

  Widget _recentDocumentTile(DocumentRecord document) {
    final activityAt = document.lastOpenedAt ?? document.createdAt;
    // The Android external chooser reports successful dispatch, not proof
    // that another application rendered and displayed the PDF.
    final activity = document.lastOpenedAt != null
        ? 'Open requested'
        : document.source == 'download'
            ? 'Downloaded'
            : 'Added';
    return Card(
      elevation: 0,
      child: ListTile(
        key: ValueKey('recent-${document.id}'),
        dense: true,
        leading: DocumentThumbnail(
          documentId: document.id,
          storagePath: document.storagePath,
          sizeBytes: document.sizeBytes,
        ),
        title: Row(children: [
          Flexible(child: Text('${document.name}.pdf',
              maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 6),
          _recentSourceTag('Grid'),
        ]),
        subtitle: Text('${_recentDateLabel(activityAt)} · $activity'),
        onTap: () => _open(document),
        onLongPress: () => _openRecentSelection(document),
        trailing: PopupMenuButton<String>(
          tooltip: 'Actions for ${document.name}',
          onSelected: (value) => _handleRecentAction(document, value),
          itemBuilder: (_) => _recentPdfMenu(document),
        ),
      ),
    );
  }

  List<PopupMenuEntry<String>> _recentPdfMenu(DocumentRecord document) => [
    const PopupMenuItem(value: 'share', child: Text('Share PDF')),
    PopupMenuItem(value: 'favorite',
      child: Text(document.isFavorite ? 'Remove from Star' : 'Add to Star')),
    const PopupMenuItem(value: 'category', child: Text('Set category')),
    const PopupMenuItem(value: 'tags', child: Text('Edit tags')),
    const PopupMenuItem(value: 'rename', child: Text('Rename')),
    const PopupMenuItem(value: 'move', child: Text('Move to folder')),
    const PopupMenuItem(value: 'trash', child: Text('Move to Recycle Bin')),
    const PopupMenuItem(value: 'details', child: Text('Details')),
  ];

  Future<void> _handleRecentAction(DocumentRecord document, String action) async {
    if (action == 'details') {
      await PdfDetailsDialog.showGrid(context, document);
      return;
    }
    if (action == 'favorite') {
      await _repository.setFavorite(document, !document.isFavorite);
      await _loadAllStarred();
      await _loadRecentDocuments();
      if (mounted) {
        setState(() {
          if (_showStarredRecent && !document.isFavorite) {
            _starredRecent.removeWhere((item) => item.id == document.id);
          }
        });
        await _refreshDashboardSummary();
      }
      return;
    }
    if (action == 'share') {
      await _share(document);
    } else if (action == 'category') {
      await _chooseCategory(document);
    } else if (action == 'tags') {
      await _editTags(document);
    } else if (action == 'rename') {
      await _rename(document);
    } else if (action == 'move') {
      await _moveToFolder(document);
    } else if (action == 'trash') {
      await _trash(document);
    }
    await _loadRecentDocuments();
    if (_showStarredRecent) await _loadAllStarred();
  }

  Future<void> _openRecentSelection(DocumentRecord first) async {
    await Navigator.of(context).push<String>(MaterialPageRoute(
      builder: (_) => _RecentSelectionScreen(
        initialDocument: first,
        loadItems: _showStarredRecent ? _repository.listAllStarred : _loadAllRecentGrid,
        onOpen: _open,
        onMove: _bulkMoveDocuments,
        onCopy: _bulkCopyDocuments,
        onDelete: _bulkDeleteDocuments,
        onShare: _bulkShareDocuments,
        onRename: _rename,
      ),
    ));
    await _loadRecentDocuments();
    await _loadAllStarred();
  }

  Future<void> _bulkMoveDocuments(List<DocumentRecord> selected) async {
    final folders = await _folderRepository.allFoldersWithPaths();
    if (!mounted) return;
    final destination = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListView(shrinkWrap: true, children: [
        const ListTile(title: Text('Move selected PDFs to')),
        ListTile(title: const Text('Root / No folder'), onTap: () => Navigator.pop(ctx, '')),
        for (final option in folders)
          ListTile(title: Text(option.path), onTap: () => Navigator.pop(ctx, option.folder.id)),
      ]),
    );
    if (destination == null) return;
    final result = await _repository.moveManyToFolder(selected, destination.isEmpty ? null : destination);
    if (mounted && (result['moved'] as int? ?? 0) != selected.length) {
      _message('Some PDFs could not be moved. Check their storage access.');
    }
  }

  Future<void> _bulkCopyDocuments(List<DocumentRecord> selected) async {
    final failures = <String>[];
    for (final document in selected) {
      try {
        await _repository.copyDocument(document, targetFolderId: document.folderId);
      } catch (error) {
        failures.add('${document.name}: $error');
      }
    }
    if (mounted && failures.isNotEmpty) {
      _message('${failures.length} of ${selected.length} PDFs could not be copied. ${failures.first}');
    }
  }

  Future<bool> _bulkDeleteDocuments(List<DocumentRecord> selected) async {
    final confirmed = await _confirmMoveToRecycleBin(
      count: selected.length,
      details: 'The selected PDFs will be hidden from Recent and moved to DocsGrid Recycle Bin. They can be restored later.',
    );
    if (!confirmed) return false;
    await _repository.moveManyToTrash(selected);
    if (mounted) {
      await _refreshDashboardSummary();
    }
    return true;
  }

  Future<void> _bulkShareDocuments(List<DocumentRecord> selected) async {
    await _tools.shareManyStoredPdfs(
      selected.map((item) => item.storagePath).toList(),
      selected.map((item) => '${item.name}.pdf').toList(),
    );
  }

  /// Manual selection is required: old Phone URIs are not portable grants.
  Future<void> _relinkPendingPhonePdf(Map<String, Object?> item) async {
    final identity = item['referenceId'] as String?;
    if (identity == null) return;
    try {
      if (_phoneEntries.isEmpty) await _scanPhoneStorage(openBrowser: false);
      if (!mounted) return;
      final candidates = <String, Map<String, Object?>>{};
      for (final row in _phoneEntries) {
        final uri = row['uri'];
        final name = row['name'];
        if (row['isDirectory'] == true || row['isInaccessible'] == true ||
            uri is! String || uri.isEmpty || name is! String ||
            !name.toLowerCase().endsWith('.pdf')) continue;
        candidates.putIfAbsent(uri, () => row);
      }
      final files = candidates.values.toList(growable: false);
      final query = TextEditingController();
      Map<String, Object?>? selected;
      try {
        selected = await showDialog<Map<String, Object?>>(
          context: context,
          builder: (dialog) => StatefulBuilder(
            builder: (dialog, update) {
              final term = query.text.trim().toLowerCase();
              final matches = files.where((row) =>
                (row['name'] as String).toLowerCase().contains(term))
                  .take(50).toList(growable: false);
              return AlertDialog(
                title: const Text('Re-link Phone PDF'),
                content: SizedBox(
                  height: 360, width: double.maxFinite,
                  child: Column(children: [
                    const Text('Choose the corresponding PDF on this device.'),
                    TextField(
                      controller: query,
                      decoration: const InputDecoration(labelText: 'Search files'),
                      onChanged: (_) => update(() {}),
                    ),
                    Expanded(child: ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (_, index) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.picture_as_pdf_outlined),
                        title: Text(matches[index]['name'] as String),
                        onTap: () => Navigator.pop(dialog, matches[index]),
                      ),
                    )),
                  ]),
                ),
                actions: [TextButton(
                  onPressed: () => Navigator.pop(dialog),
                  child: const Text('Cancel'),
                )],
              );
            },
          ),
        );
      } finally {
        query.dispose();
      }
      if (selected == null) return;
      final uri = selected['uri'] as String;
      final name = selected['name'] as String;
      await StorageLocationService.instance.sha256Pdf(uri);
      await PhonePortableState.relink(
        referenceId: identity, selectedUri: uri, selectedName: name,
      );
      await _loadPhoneStarred();
      await _loadRecentDocuments();
    } catch (error) {
      if (mounted) _message('Phone PDF could not be re-linked: $error');
    }
  }

  Widget _phoneStarredTile(Map<String, Object?> item) {
    final uri = item['uri'] as String;
    final name = item['name'] as String? ?? 'PDF';
    final unresolved = item['needsRelinking'] == true;
    return ListTile(
      key: ValueKey('phone-starred-$uri'),
      dense: true,
      leading: unresolved ? const Icon(Icons.link_off_outlined) : DocumentThumbnail(
        documentId: 'phone_starred_$uri',
        storagePath: uri,
        sizeBytes: (item['sizeBytes'] as num?)?.toInt() ?? 0,
      ),
      title: Row(children: [
        Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 6),
        _recentSourceTag('Phone'),
      ]),
      subtitle: Text(unresolved ? 'Starred · Re-link this PDF on this device' : 'Starred'),
      onTap: unresolved ? () => _relinkPendingPhonePdf(item)
          : () => _openExternalStoragePdf(uri, name),
      trailing: unresolved ? null : PopupMenuButton<String>(
        tooltip: 'Actions for $name',
        onSelected: (action) => _handlePhoneRecentAction(item, action),
        itemBuilder: (_) => _phoneRecentMenu(item),
      ),
    );
  }

  Widget _phoneRecentTile(Map<String, Object?> item) {
    final name = item['name'] as String? ?? 'PDF';
    final uri = item['uri'] as String? ?? '';
    final openedAt = DateTime.tryParse(item['openedAt']?.toString() ?? '');
    final addedAt = DateTime.tryParse(item['addedAt']?.toString() ?? '');
    // External PDF choosers only acknowledge dispatch, not actual rendering.
    final unresolved = item['needsRelinking'] == true;
    final activity = unresolved ? 'Re-link required'
        : openedAt == null && addedAt != null ? 'Added' : 'Open requested';
    return ListTile(
      key: ValueKey('phone-recent-$uri'),
      dense: true,
      leading: unresolved ? const Icon(Icons.link_off_outlined) : DocumentThumbnail(
        documentId: 'phone_recent_$uri',
        storagePath: uri,
        sizeBytes: (item['sizeBytes'] as num?)?.toInt() ?? 0,
      ),
      title: Row(children: [
        Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 6),
        _recentSourceTag('Phone'),
      ]),
      subtitle: Text('$activity · ${_recentDateLabel(openedAt ?? addedAt ?? DateTime.now())}'),
      onTap: unresolved ? () => _relinkPendingPhonePdf(item)
          : () => _openExternalStoragePdf(uri, name),
      onLongPress: unresolved ? null : () => _openPhoneRecentSelection(item),
      trailing: unresolved ? null : PopupMenuButton<String>(
        tooltip: 'Actions for $name',
        onSelected: (action) => _handlePhoneRecentAction(item, action),
        itemBuilder: (_) => _phoneRecentMenu(item),
      ),
    );
  }

  Future<void> _loadRecentDocuments() async {
    final generation = ++_recentLoadGeneration;
    if (_isStartupHome) StartupTimeline.mark('home_recent_start');
    try {
      // The cutoff is presentation-only: it hides older Grid Recent entries,
      // not stored documents. Reopening or adding a PDF makes it recent again.
      final boundary =
          await StorageLocationService.instance.gridStorageBoundary();
      _gridBoundary = boundary;
      final since = await GridRecentHistory.lastClearedAt();
      final recentDocuments =
          await _repository.recentActivity(limit: 20, since: since);
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList('docsgrid_phone_recent_v1') ?? const <String>[];
      final phone = <Map<String, Object?>>[];
      for (final item in saved) {
        try {
          final decoded = jsonDecode(item);
          if (decoded is Map && decoded['uri'] is String && decoded['name'] is String) {
            phone.add(Map<String, Object?>.from(decoded));
          }
        } catch (_) {
          // Skip malformed optional recent metadata without affecting PDFs.
        }
      }
      final unlinkedRecent = (await PhonePortableState.pending())
          .where((item) => item['wasRecent'] == true)
          .toList(growable: false);
      final visiblePhone = boundary.filterEntries(
          [...unlinkedRecent, ...phone]);
      if (!mounted || generation != _recentLoadGeneration) return;
      setState(() {
        _gridRecent = recentDocuments;
        _phoneRecent =
            visiblePhone.take(20).toList(growable: false);
        _liveGridRecentLoaded = true;
        _cachedGridRecentNames = const [];
      });
      if (_isStartupHome) StartupTimeline.mark('home_recent_ready');
      if (!widget.phoneOnly && !widget.favoritesOnly && !widget.recentOnly) {
        // Names only. Do not persist IDs, paths, actions or raw PDF bytes.
        unawaited(_homeCache.saveRecentNames(
          recentDocuments.map((document) => document.name).toList(growable: false),
        ));
      }
    } catch (_) {
      if (_isStartupHome) StartupTimeline.mark('home_recent_failed');
      // Recent metadata is optional and must not block the dashboard.
    }
  }

  Future<void> _recordPhoneRecent(String uri, String name) async {
    try {
      final matchingEntries =
          _phoneEntries.where((entry) => entry['uri'] == uri).toList();
      final bytes = matchingEntries.isEmpty
          ? 0
          : (matchingEntries.first['sizeBytes'] as num?)?.toInt() ?? 0;
      final folderPath = matchingEntries.isEmpty
          ? null : (matchingEntries.first['folderPath'] ?? matchingEntries.first['path']) as String?;
      await PhoneRecentHistory.recordOpened(
        uri, name, sizeBytes: bytes, folderPath: folderPath,
      );
      if (mounted && !widget.phoneOnly) {
        await _loadRecentDocuments();
      }
    } catch (_) {
      // Failure to save optional recent metadata must not affect PDF opening.
    }
  }

  Future<void> _openExternalStoragePdf(String uri, String name) async {
    try {
      if (uri.startsWith('file://')) {
        final path = Uri.parse(uri).toFilePath();
        final result = await OpenFilex.open(path, type: 'application/pdf');
        if (result.type != ResultType.done) {
          throw StateError(result.message.isEmpty ? 'No PDF viewer is available.' : result.message);
        }
      } else {
        await StorageLocationService.instance.openPdf(uri);
      }
      await _recordPhoneRecent(uri, name);
    } catch (error) {
      if (mounted) _message('Could not open $name: $error');
    }
  }



  void _startSelection(DocumentRecord document) {
    if (!mounted) return;
    setState(() {
      _selectionMode = true;
      _selectedIds.add(document.id);
    });
  }

  void _toggleSelected(DocumentRecord document) {
    setState(() {
      _selectionMode = true;
      if (!_selectedIds.add(document.id)) _selectedIds.remove(document.id);
      if (_selectedIds.isEmpty) _selectionMode = false;
    });
  }

  void _clearSelection() {
    if (!mounted) return;
    setState(() {
      _selectedIds.clear();
      _selectionMode = false;
    });
  }

  Future<void> _bulkTrash() async {
    final selected = _documents.where((d) => _selectedIds.contains(d.id)).toList();
    if (selected.isEmpty) return;
    final confirmed = await _confirmMoveToRecycleBin(
      count: selected.length,
      details: 'The selected PDFs will be hidden from the library. Files are kept in Recycle Bin and can be restored.',
    );
    if (!confirmed) return;
    await _repository.moveManyToTrash(selected);
    if (!mounted) return;
    setState(() {
      _selectedIds.clear();
      _selectionMode = false;
      _documents.removeWhere((document) => selected.any((item) => item.id == document.id));
    });
    await _refreshDashboardSummary();
  }

  Future<void> _bulkShare() async {
    final selected = _documents.where((d) => _selectedIds.contains(d.id)).toList();
    if (selected.isEmpty) return;
    try {
      await _tools.shareManyStoredPdfs(
        selected.map((d) => d.storagePath).toList(),
        selected.map((d) => '${d.name}.pdf').toList(),
      );
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share selected PDFs: $error')));
    } finally {
      if (mounted) _clearSelection();
    }
  }
  Future<void> _bulkMove() async {
    final selected = _documents.where((d) => _selectedIds.contains(d.id)).toList();
    if (selected.isEmpty) return;
    final folders = await _folderRepository.allFoldersWithPaths();
    if (!mounted) return;
    final destination = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Move selected PDFs to')),
            ListTile(leading: const Icon(Icons.home_outlined), title: const Text('Root / No folder'), onTap: () => Navigator.pop(sheetContext, '')),
            for (final option in folders)
              ListTile(leading: const Icon(Icons.folder_outlined), title: Text(option.path), onTap: () => Navigator.pop(sheetContext, option.folder.id)),
          ],
        ),
      ),
    );
    if (destination == null) return;
    final result = await _repository.moveManyToFolder(selected, destination.isEmpty ? null : destination);
    if (!mounted) return;
    _clearSelection();
    for (final document in selected) {
      await _patchDocument(document.id);
    }
    await _refreshDashboardSummary();
    if (!mounted) return;
    final failures = result['failures'] as List<String>;
    if (failures.isNotEmpty) {
      _message('${failures.length} selected PDFs could not be moved. ${failures.first}');
    }
  }

  Future<void> _open(DocumentRecord document) async {
    try {
      await StorageLocationService.instance.openPdf(
        document.storagePath, gridPdf: true,
      );
      await _repository.markOpened(document);
      if (!mounted) return;
      await _patchDocument(document.id);
      await _loadRecentDocuments();
    } catch (error) {
      if (mounted) _message('Could not open PDF: $error');
    }
  }

  Future<void> _share(DocumentRecord document) async {
    try {
      await _tools.shareStoredPdf(document.storagePath, '${document.name}.pdf');
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not share PDF: $error')),
        );
      }
    }
  }

  Future<void> _relink(DocumentRecord document) async {
    try {
      await _repository.relinkDocument(document);
      await _patchDocument(document.id);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF recovery failed: $error')),
        );
      }
    }
  }

  Future<bool> _rename(DocumentRecord document) async {
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
    if (value == null) return false;
    try {
      await _repository.rename(document, value);
      await _patchDocument(document.id);
      return true;
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
      return false;
    }
  }

  Future<void> _addReminder(DocumentRecord document) async {
    final title = TextEditingController(text: 'Renewal - ${document.name}');
    final note = TextEditingController();
    var selected = DateTime.now().add(const Duration(days: 1));
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          scrollable: true,
          title: const Text('Add to reminder'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, decoration: const InputDecoration(labelText: 'Reminder title')),
            TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'Note (optional)')),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Date & time'),
              subtitle: Text('${selected.day.toString().padLeft(2, '0')}/${selected.month.toString().padLeft(2, '0')}/${selected.year} · ${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}'),
              onTap: () async {
                final date = await showDatePicker(context: context, initialDate: selected, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 3650)));
                if (date == null || !context.mounted) return;
                final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(selected));
                if (time != null) refresh(() => selected = DateTime(date.year, date.month, date.day, time.hour, time.minute));
              },
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(onPressed: () {
              if (title.text.trim().isNotEmpty && selected.isAfter(DateTime.now())) Navigator.pop(dialogContext, true);
            }, child: const Text('Save')),
          ],
        ),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    final reminderTitle = title.text.trim();
    final reminderNote = note.text.trim();
    title.dispose();
    note.dispose();
    if (saved != true) return;
    try {
      await ReminderRepository().create(
        title: reminderTitle,
        note: reminderNote,
        remindAt: selected,
        documentId: document.id,
      );
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save reminder: $error')));
    }
  }

  Future<void> _showTrash() async {
    final trashed = await _repository.listTrash();
    final trashedFolders = await _folderRepository.listTrashFolderRoots();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => RecycleBinDialog(
        folders: trashedFolders,
        pdfs: trashed,
        inspectFolder: _folderRepository.trashFolderContents,
        restoreFolder: (id) async {
          await _folderRepository.restoreTrashFolderTree(id);
        },
        deleteFolder: _folderRepository.permanentlyDeleteTrashFolderTree,
        restorePdf: _repository.restoreFromTrash,
        deletePdf: _repository.permanentlyDelete,
        onChanged: ({required bool pdfChanged}) async {
          if (!mounted) return;
          await _load();
          if (pdfChanged) await _scanPhoneStorage(openBrowser: false);
          await _loadRecentDocuments();
          await _refreshDashboardSummary();
        },
      ),
    );
    if (mounted) await _refreshDashboardSummary();
  }

  Future<void> _chooseCategory(DocumentRecord document) async {
    final categories = await _categoryRepository.listCategories();
    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Choose category'),
              subtitle: Text('This changes only the document label.'),
            ),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline),
              title: const Text('No category'),
              onTap: () => Navigator.pop(sheetContext, ''),
            ),
            for (final category in categories)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(category.name),
                trailing: document.categoryId == category.id
                    ? const Icon(Icons.check, color: Colors.green)
                    : null,
                onTap: () => Navigator.pop(sheetContext, category.id),
              ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    await _categoryRepository.setDocumentCategory(
      document.id,
      selected.isEmpty ? null : selected,
    );
    await _patchDocument(document.id);
  }

  Future<void> _editTags(DocumentRecord document) async {
    final tags = await _categoryRepository.listTags();
    if (!mounted) return;
    final current = await _categoryRepository.tagsForDocument(document.id);
    if (!mounted) return;
    final selected = current.map((tag) => tag.id).toSet();
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, refresh) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ListTile(
                  title: Text('Document tags'),
                  subtitle: Text('Select one or more reusable tags.'),
                ),
                if (tags.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('No tags created yet. Add tags in Settings → Categories & tags.'),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 360),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final tag in tags)
                          CheckboxListTile(
                            value: selected.contains(tag.id),
                            title: Text(tag.name),
                            onChanged: (checked) => refresh(() {
                              if (checked == true) {
                                selected.add(tag.id);
                              } else {
                                selected.remove(tag.id);
                              }
                            }),
                          ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(sheetContext, selected),
                      child: const Text('Save tags'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (result == null) return;
    await _categoryRepository.setDocumentTags(document.id, result.toList());
    await _patchDocument(document.id);
  }

  Future<bool> _trashPhonePdf(String uri, String name) async {
    final confirmed = await _confirmMoveToRecycleBin(
      count: 1,
      details: '$name will first be safely archived in DocsGrid Recycle Bin. The Phone original is removed only after the archive succeeds.',
    );
    if (!confirmed) return false;
    try {
      final origin = await _phoneTrashOriginFor(uri, name);
      final moved = await _repository.moveExternalPdfToTrash(
        sourceUri: uri,
        displayName: name,
        origin: origin,
      );
      if (!mounted) return false;
      if (moved) {
        try { await PhoneStarRepository.remove(uri); } catch (_) {}
        await _loadPhoneStarred();
        final prefs = await SharedPreferences.getInstance();
        final keep = _phoneRecent
            .where((item) => item['uri'] != uri)
            .toList(growable: false);
        await prefs.setStringList(
          'docsgrid_phone_recent_v1',
          keep.map(jsonEncode).toList(),
        );
        if (mounted) setState(() => _phoneRecent = keep);
      } else {
        _message('A matching PDF already exists in Grid. The Phone original was kept.');
      }
      await _scanPhoneStorage(openBrowser: false);
      await _loadTrashSummary();
      await _refreshDashboardSummary();
      return moved;
    } catch (error) {
      if (mounted) {
        _message('Could not safely move PDF to Recycle Bin. The Phone original was kept: $error');
      }
      return false;
    }
  }

  Future<bool> _renamePhonePdf(String uri, String currentName) async {
    final controller = TextEditingController(
      text: currentName.toLowerCase().endsWith('.pdf')
          ? currentName.substring(0, currentName.length - 4)
          : currentName,
    );
    final requested = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename PDF'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(labelText: 'File name', suffixText: '.pdf'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (requested == null) return false;
    final clean = requested.trim();
    if (clean.isEmpty || clean.contains('/') || clean.contains('\\') || clean == '.' || clean == '..') {
      _message('Enter a valid file name.');
      return false;
    }
    try {
      final newName = clean.toLowerCase().endsWith('.pdf') ? clean : '$clean.pdf';
      final newUri = await StorageLocationService.instance.renamePdf(
        uri: uri, name: newName,
      );
      // Native rename is already committed. A shortcut preference failure must
      // not be mistaken for a failed physical rename.
      String? shortcutWarning;
      try {
        await PhoneReferenceIdentity.renamed(uri, newUri);
        await PhoneStarRepository.updateRenamedReference(uri, newUri, newName);
        await PhoneRecentHistory.updateRenamedReference(uri, newUri, newName);
      } catch (error) {
        shortcutWarning = 'PDF renamed, but its Star/Recent shortcut needs attention: $error';
      }
      if (!mounted) return true;
      await _loadPhoneStarred();
      await _scanPhoneStorage(openBrowser: false);
      await _refreshDashboardSummary();
      if (mounted && shortcutWarning != null) _message(shortcutWarning);
      return true;
    } catch (error) {
      if (mounted) _message('Could not rename PDF: $error');
      return false;
    }
  }


  Future<void> _sharePhoneSelectedPdfs(
    List<Map<String, Object?>> selected,
  ) async {
    if (selected.isEmpty) return;
    await _tools.shareManyStoredPdfs(
      selected.map((row) => row['uri'] as String).toList(growable: false),
      selected.map((row) => row['name'] as String).toList(growable: false),
    );
  }

  /// Select one destination for the entire Phone selection. Grid is routed
  /// through the managed import service; physical Phone moves remain separate.
  Future<bool> _movePhoneSelectedWithinPhone(
    List<Map<String, Object?>> selected,
  ) async {
    if (selected.isEmpty) return false;
    final storage = StorageLocationService.instance;
    List<Map<String, String>> roots = [];
    try {
      roots = await storage.accessibleStorageRoots();
    } catch (_) {
      // Grid remains available even when Phone roots cannot be enumerated.
    }
    if (!mounted) return false;
    final sourcePaths = selected.map((row) =>
        (row['folderPath'] ?? row['path'] ?? '').toString()).toSet();
    final destination = await showModalBottomSheet<PhoneFolderDestination>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.75,
        child: PhoneMoveFolderPicker(
          roots: roots,
          excludedGrid: _gridBoundary,
          sourceFolderPath: sourcePaths.length == 1 ? sourcePaths.single : '',
          allowGridDestination: true,
          listDirectory: storage.listDirectory,
          createDirectory: (parent, folderName) =>
              storage.createDirectory(parentUri: parent, name: folderName),
        ),
      ),
    );
    if (destination == null || !mounted) return false;
    if (destination.isGrid) return _movePhonePdfsToGrid(selected);
    final movedSources = <String>{};
    var failed = 0;
    for (final entry in selected) {
      final uri = entry['uri'] as String;
      final name = entry['name'] as String;
      try {
        // Source is removed only by PhonePdfMoveService after verified copy.
        final newUri = await const PhonePdfMoveService().move(
          sourceUri: uri,
          displayName: name,
          destinationFolderUri: destination.uri,
        );
        movedSources.add(uri);
        try {
          final wasStarred = _phoneStarredUris.contains(uri);
          await PhoneStarRepository.remove(uri);
          if (wasStarred) {
            await PhoneStarRepository.toggle(
              uri: newUri,
              name: name,
              folderPath: destination.path,
              sizeBytes: (entry['sizeBytes'] as num?)?.toInt() ?? 0,
            );
          }
        } catch (_) {
          // Optional Star metadata never rolls back verified file moves.
        }
        try { await PhoneRecentHistory.removeMovedSource(uri); } catch (_) {}
      } catch (_) {
        failed++;
      }
    }
    if (movedSources.isNotEmpty) {
      if (mounted) {
        setState(() {
          _phoneRecent = _phoneRecent.where(
              (row) => !movedSources.contains(row['uri']))
              .toList(growable: false);
          _phoneEntries = _phoneEntries.where(
              (row) => !movedSources.contains(row['uri']))
              .toList(growable: false);
        });
      }
      try { await _loadPhoneStarred(); } catch (_) {}
      try {
        if (mounted) {
          await _scanPhoneStorage(openBrowser: false);
          await _refreshDashboardSummary();
        }
      } catch (_) {
        // Next storage refresh reconciles an already verified move.
      }
    }
    if (mounted && failed > 0) {
      _message('$failed Phone PDFs were kept in their original folders.');
    }
    return movedSources.isNotEmpty;
  }

  /// Archive each Phone original through the existing checksum-safe service;
  /// a duplicate or failed archive always leaves that original untouched.
  Future<bool> _trashPhoneSelectedPdfs(
    List<Map<String, Object?>> selected,
  ) async {
    if (selected.isEmpty) return false;
    if (selected.length == 1) {
      final entry = selected.single;
      return _trashPhonePdf(entry['uri'] as String, entry['name'] as String);
    }
    final confirmed = await _confirmMoveToRecycleBin(
      count: selected.length,
      details: 'Each Phone PDF is safely archived in DocsGrid Recycle Bin '
          'before its original is removed. Failed or duplicate archives '
          'keep their originals.',
    );
    if (!confirmed || !mounted) return false;
    final movedSources = <String>{};
    var kept = 0;
    for (final entry in selected) {
      final uri = entry['uri'] as String;
      final name = entry['name'] as String;
      try {
        final origin = await _phoneTrashOriginFor(uri, name);
        final success = await _repository.moveExternalPdfToTrash(
          sourceUri: uri,
          displayName: name,
          origin: origin,
        );
        if (!success) {
          kept++;
          continue;
        }
        movedSources.add(uri);
        try { await PhoneStarRepository.remove(uri); } catch (_) {}
      } catch (_) {
        kept++;
      }
    }
    if (movedSources.isNotEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final keep = _phoneRecent.where(
            (row) => !movedSources.contains(row['uri']))
            .toList(growable: false);
        await prefs.setStringList('docsgrid_phone_recent_v1',
            keep.map(jsonEncode).toList());
        if (mounted) setState(() => _phoneRecent = keep);
      } catch (_) {}
      try { await _loadPhoneStarred(); } catch (_) {}
    }
    try {
      if (mounted) {
        await _scanPhoneStorage(openBrowser: false);
        await _loadTrashSummary();
        await _refreshDashboardSummary();
      }
    } catch (_) {}
    if (mounted && kept > 0) {
      _message('$kept Phone PDF originals were kept safely.');
    }
    return movedSources.isNotEmpty;
  }

  Future<void> _sharePhonePdf(String uri, String name) async {
    try {
      await _tools.shareStoredPdf(uri, name);
    } catch (error) {
      if (mounted) _message('Could not share PDF: $error');
    }
  }

  Future<bool> _movePhonePdfToGrid(String uri, String name) =>
      _movePhonePdfsToGrid([{'uri': uri, 'name': name}]);

  Future<String?> _chooseGridMoveDestination(int count) async {
    var folders = await _folderRepository.allFoldersWithPaths();
    if (!mounted) return null;
    var selectedFolderId = '';
    final destination = await showDialog<String?>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: Text(count == 1 ? 'Move PDF to Grid' : 'Move $count PDFs to Grid'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Folder'),
              DropdownButtonFormField<String>(
                value: selectedFolderId,
                isExpanded: true,
                items: [
                  const DropdownMenuItem(value: '', child: Text('Root')),
                  for (final folder in folders)
                    DropdownMenuItem(
                      value: folder.folder.id,
                      child: Text(folder.path, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (value) => refresh(() => selectedFolderId = value ?? ''),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('Create folder'),
                  onPressed: () async {
                    final controller = TextEditingController();
                    final folderName = await showDialog<String>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Create Grid folder'),
                        content: TextField(
                          controller: controller,
                          autofocus: true,
                          decoration: const InputDecoration(labelText: 'Folder name'),
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Create')),
                        ],
                      ),
                    );
                    controller.dispose();
                    if (folderName == null || folderName.isEmpty) return;
                    try {
                      await _folderRepository.create(
                        name: folderName,
                        parentId: selectedFolderId.isEmpty ? null : selectedFolderId,
                      );
                      folders = await _folderRepository.allFoldersWithPaths();
                      selectedFolderId = folders
                          .where((folder) => folder.folder.name == folderName)
                          .map((folder) => folder.folder.id)
                          .firstOrNull ?? '';
                      refresh(() {});
                    } catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Could not create folder: $error')),
                        );
                      }
                    }
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, selectedFolderId),
              child: const Text('Move'),
            ),
          ],
        ),
      ),
    );
    return destination;
  }

  /// Each original is removed only by the existing verified Grid import.
  /// One destination is selected, then refresh Phone and Grid once per batch.
  Future<bool> _movePhonePdfsToGrid(
    List<Map<String, Object?>> selected,
  ) async {
    if (selected.isEmpty) return false;
    String? destination;
    try {
      destination = await _chooseGridMoveDestination(selected.length);
    } catch (error) {
      if (mounted) _message('Could not open Grid folders: $error');
      return false;
    }
    if (destination == null || !mounted) return false;
    final movedSources = <String>{};
    var duplicates = 0;
    var failed = 0;
    var recentSaved = true;
    for (final entry in selected) {
      final uri = entry['uri'] as String;
      final name = entry['name'] as String;
      try {
        final result = await _repository.moveExternalPdfToGrid(
          sourceUri: uri,
          displayName: name,
          targetFolderId: destination.isEmpty ? null : destination,
        );
        if (result.added != 1) {
          if (result.duplicates > 0) {
            duplicates++;
          } else {
            failed++;
          }
          continue;
        }
        movedSources.add(uri);
        try { await PhoneStarRepository.remove(uri); } catch (_) {}
        try {
          await PhoneRecentHistory.removeMovedSource(uri);
        } catch (_) {
          recentSaved = false;
        }
      } catch (_) {
        // Import may have succeeded before provider deletion failed.
        // Never delete another copy or claim that the move completed.
        failed++;
      }
    }
    if (mounted) {
      if (movedSources.isNotEmpty) {
        setState(() {
          _phoneRecent = _phoneRecent.where(
              (row) => !movedSources.contains(row['uri']))
              .toList(growable: false);
          _phoneEntries = _phoneEntries.where(
              (row) => !movedSources.contains(row['uri']))
              .toList(growable: false);
          _recentFilter = 'grid';
        });
      }
      try {
        await _loadPhoneStarred();
        await _loadRecentDocuments();
        await _scanPhoneStorage(openBrowser: false);
        await _load();
        await _refreshDashboardSummary();
      } catch (error) {
        if (mounted) _message('Storage refresh needs attention: $error');
      }
      if (mounted && (duplicates > 0 || failed > 0 || !recentSaved)) {
        _message('Moved ${movedSources.length} of ${selected.length} PDFs to Grid. '
            '${duplicates > 0 ? "$duplicates duplicate originals kept. " : ""}'
            '${failed > 0 ? "$failed moves not confirmed; check both locations. " : ""}'
            '${recentSaved ? "" : "Phone Recent cleanup needs attention."}');
      }
    }
    return movedSources.isNotEmpty;
  }

  /// The Phone three-dot Move action changes only the physical Phone file.
  /// Grid's PDF metadata, folders and duplicate rules are never modified.
  Future<bool> _movePhonePdfWithinPhone(String uri, String name) async {
    final storage = StorageLocationService.instance;
    List<Map<String, String>> roots;
    try {
      roots = await storage.accessibleStorageRoots();
    } catch (error) {
      if (mounted) _message('Could not list Phone storage locations: $error');
      return false;
    }
    if (!mounted) return false;
    if (roots.isEmpty) {
      _message('No accessible Phone folders. Check storage access in Settings.');
      return false;
    }
    final matches = <Map<String, Object?>>[
      ..._phoneEntries.where((row) => row['uri'] == uri),
      ..._phoneRecent.where((row) => row['uri'] == uri),
      ..._phoneStarred.where((row) => row['uri'] == uri),
    ];
    final sourceFolderPath = matches.isEmpty ? ''
        : (matches.first['folderPath'] ?? matches.first['path'] ?? '').toString();
    final sourceSize = matches.isEmpty ? 0
        : (matches.first['sizeBytes'] as num?)?.toInt() ?? 0;

    final destination = await showModalBottomSheet<PhoneFolderDestination>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.75,
        child: PhoneMoveFolderPicker(
          roots: roots,
          excludedGrid: _gridBoundary,
          sourceFolderPath: sourceFolderPath,
          listDirectory: storage.listDirectory,
          createDirectory: (parent, folderName) =>
              storage.createDirectory(parentUri: parent, name: folderName),
        ),
      ),
    );
    if (destination == null || !mounted) return false;

    String movedUri;
    try {
      movedUri = await const PhonePdfMoveService().move(
        sourceUri: uri,
        displayName: name,
        destinationFolderUri: destination.uri,
      );
    } catch (error) {
      if (mounted) _message('Phone PDF was not moved: $error');
      return false;
    }

    // Preserve optional Phone Star across the URI change. This metadata
    // cleanup must never undo a successful, checksum-verified file move.
    try {
      final wasStarred = _phoneStarredUris.contains(uri);
      await PhoneStarRepository.remove(uri);
      if (wasStarred) {
        await PhoneStarRepository.toggle(
          uri: movedUri, name: name,
          folderPath: destination.path, sizeBytes: sourceSize,
        );
      }
      await _loadPhoneStarred();
    } catch (_) {}
    try { await PhoneRecentHistory.removeMovedSource(uri); } catch (_) {}
    if (mounted) {
      setState(() {
        _phoneRecent = _phoneRecent.where((row) => row['uri'] != uri)
            .toList(growable: false);
        _phoneEntries = _phoneEntries.where((row) => row['uri'] != uri)
            .toList(growable: false);
      });
      // Success is visible immediately in the refreshed Phone list.
    }
    try {
      if (mounted) {
        await _scanPhoneStorage(openBrowser: false);
        await _refreshDashboardSummary();
      }
    } catch (_) {
      // The next Phone scan will reconcile the already successful move.
    }
    return true;
  }

  Future<void> _moveToFolder(DocumentRecord document) async {
    final storage = StorageLocationService.instance;
    final gridFolders = await _folderRepository.allFoldersWithPaths();
    final roots = await storage.accessibleStorageRoots();
    if (!mounted) return;
    final phoneRoot = roots.isEmpty ? null : roots.first['uri'];
    var location = 'grid';
    var gridFolderId = '';
    String? phoneFolderUri = phoneRoot;
    var phoneFolders = <Map<String, Object?>>[];

    Future<void> refreshPhoneFolders() async {
      if (phoneFolderUri == null) return;
      final entries = await storage.listDirectory(phoneFolderUri!);
      phoneFolders = entries.where((entry) => entry['isDirectory'] == true).toList();
    }

    if (phoneRoot != null) await refreshPhoneFolders();
    final selected = await showDialog<({String location, String? folderId, String? uri})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Move PDF'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Location'),
            DropdownButtonFormField<String>(
              value: location,
              items: [
                const DropdownMenuItem(value: 'grid', child: Text('Grid')),
                DropdownMenuItem(value: 'internal', enabled: phoneRoot != null, child: const Text('Internal storage')),
              ],
              onChanged: (value) async {
                if (value == null) return;
                setDialogState(() => location = value);
                if (value == 'internal') {
                  phoneFolderUri = phoneRoot;
                  try { await refreshPhoneFolders(); setDialogState(() {}); }
                  catch (error) { if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Storage access failed: $error'))); }
                }
              },
            ),
            const SizedBox(height: 12),
            const Text('Folder'),
            if (location == 'grid')
              DropdownButtonFormField<String>(
                value: gridFolderId,
                isExpanded: true,
                items: [
                  const DropdownMenuItem(value: '', child: Text('Root')),
                  for (final folder in gridFolders) DropdownMenuItem(value: folder.folder.id, child: Text(folder.path, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (value) => setDialogState(() => gridFolderId = value ?? ''),
              )
            else
              DropdownButtonFormField<String>(
                value: phoneFolderUri,
                isExpanded: true,
                items: [
                  if (phoneRoot != null) DropdownMenuItem(value: phoneRoot, child: const Text('Root')),
                  for (final folder in phoneFolders) DropdownMenuItem(value: folder['uri'] as String, child: Text(folder['name'] as String, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (value) => setDialogState(() => phoneFolderUri = value),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Create folder'),
                onPressed: () async {
                  final controller = TextEditingController();
                  final name = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
                    title: const Text('Create folder'),
                    content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'Folder name')),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Create')),
                    ],
                  ));
                  controller.dispose();
                  if (name == null || name.isEmpty) return;
                  try {
                    if (location == 'internal') {
                      final parent = phoneFolderUri ?? phoneRoot;
                      if (parent == null) throw StateError('Internal storage is unavailable.');
                      phoneFolderUri = await storage.createDirectory(parentUri: parent, name: name);
                      await refreshPhoneFolders();
                    } else {
                      await _folderRepository.create(name: name, parentId: gridFolderId.isEmpty ? null : gridFolderId);
                      gridFolders
                        ..clear()
                        ..addAll(await _folderRepository.allFoldersWithPaths());
                      gridFolderId = gridFolders.where((item) => item.folder.name == name).map((item) => item.folder.id).firstOrNull ?? '';
                    }
                    setDialogState(() {});
                  } catch (error) {
                    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create folder: $error')));
                  }
                },
              ),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, (
              location: location,
              folderId: location == 'grid' ? gridFolderId : null,
              uri: location == 'internal' ? phoneFolderUri : null,
            )), child: const Text('Move')),
          ],
        ),
      ),
    );
    if (selected == null) return;
    await _repository.moveToFolder(
      document,
      selected.location == 'grid' && selected.folderId!.isNotEmpty ? selected.folderId : null,
      destinationUri: selected.location == 'internal' ? selected.uri : null,
    );
    await _patchDocument(document.id);
  }

  Future<void> _trash(DocumentRecord document) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move to Recycle Bin?'),
        content: Text('${document.name}.pdf will be hidden from the library. The file is not erased.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Move')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repository.moveToTrash(document);
    if (!mounted) return;
    setState(() {
      _documents.removeWhere((item) => item.id == document.id);
      _selectedIds.remove(document.id);
    });
    await _refreshDashboardSummary();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.phoneOnly) {
      return PhoneStorageBrowserScreen(
        rootName: Platform.isIOS ? 'Files' : 'Internal Storage',
        entries: _phoneEntries,
        onOpenPdf: _openExternalStoragePdf,
        onMovePdf: _movePhonePdfToGrid,
        onMoveWithinPhone: _movePhonePdfWithinPhone,
        onRenamePdf: _renamePhonePdf,
        onSharePdf: _sharePhonePdf,
        onShareSelectedPdfs: _sharePhoneSelectedPdfs,
        onMoveSelectedWithinPhone: _movePhoneSelectedWithinPhone,
        onTrashSelectedPdfs: _trashPhoneSelectedPdfs,
        onToggleStarPdf: _recordExternalFavorite,
        starredUris: _phoneStarredUris,
        onTrashPdf: _trashPhonePdf,
        embedded: true,
        active: widget.active,
        onBackAtRoot: widget.onBackAtRoot,
        cacheScope: '${_phoneLastRoots.map((root) => root['uri'] ?? '').join('|')}'
            '|grid:${_gridBoundary.signature}',
        // Keep the last usable index visible while refresh continues silently.
        isLoading: _phoneScanLoading && _phoneEntries.isEmpty,
        onRefresh: () => _scanPhoneStorage(openBrowser: true),
      );
    }
    return PopScope<void>(
      canPop: !widget.active ||
          (!_selectionMode && widget.onBackAtRoot == null),
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || !widget.active || !mounted) return;
        if (_selectionMode) {
          _clearSelection();
        } else {
          widget.onBackAtRoot?.call();
        }
      },
      child: RefreshIndicator(
        onRefresh: _load,
        child: SingleChildScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
      children: [
        if (_selectionMode)
          Material(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(children: [
                IconButton(tooltip: 'Clear selection', onPressed: _clearSelection, icon: const Icon(Icons.close)),
                Expanded(child: Text('${_selectedIds.length} selected', style: const TextStyle(fontWeight: FontWeight.w700))),
                IconButton(tooltip: 'Share selected', onPressed: _bulkShare, icon: const Icon(Icons.share_outlined)),
                IconButton(tooltip: _selectedIds.length == _documents.length ? 'Clear all selection' : 'Select all', onPressed: () => setState(() { if (_selectedIds.length == _documents.length) { _selectedIds.clear(); } else { _selectedIds.addAll(_documents.map((d) => d.id)); } }), icon: const Icon(Icons.select_all)),
                IconButton(tooltip: 'Move selected', onPressed: _bulkMove, icon: const Icon(Icons.drive_file_move_outline)),
                IconButton(tooltip: 'Move selected to Recycle Bin', onPressed: _bulkTrash, icon: const Icon(Icons.delete_outline)),
              ]),
            ),
          ),
        if (!widget.favoritesOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    decoration: InputDecoration(
                      hintText: 'Search PDF names',
                      prefixIcon: const Icon(Icons.search),
                      suffixIconConstraints: const BoxConstraints(minHeight: 48, minWidth: 0),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_search.text.isNotEmpty)
                            IconButton(
                              tooltip: 'Clear search',
                              onPressed: _search.clear,
                              icon: const Icon(Icons.close),
                            ),
                        ],
                      ),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: _gridView ? 'Switch to list view' : 'Switch to grid view',
                  onPressed: _toggleDocumentView,
                  icon: Icon(_gridView ? Icons.view_list_outlined : Icons.grid_view_outlined),
                ),

              ],
            ),
          ),
        if (!widget.favoritesOnly && !widget.recentOnly &&
            _search.text.trim().isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFAAB7F2), Color(0xFF687BCB)],
                ),
                borderRadius: BorderRadius.circular(28),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Your library', style: TextStyle(color: Color(0xFF17203D), fontSize: 16)),
                  const SizedBox(height: 2),
                  Text('$_totalDocumentCount PDFs', style: const TextStyle(
                    color: Color(0xFF10162C), fontSize: 32, fontWeight: FontWeight.w800,
                  )),
                  if (_showCachedHomeSummary)
                    const Text('Previous summary · refreshing live counts',
                      style: TextStyle(color: Color(0xFF17203D), fontSize: 10)),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: _dashboardStorageMetric(
                      icon: Icons.phone_android_outlined,
                      title: 'Phone storage',
                      value: Platform.isAndroid
                          ? _phoneHasAllFilesAccess == null
                              ? (_phoneScanLoading ? 'Checking…' : 'Tap to check')
                              : !_phoneHasAllFilesAccess!
                                  ? 'Permission needed'
                                  : _phoneStorageBytes == null
                                      ? 'Access granted'
                                      : _size(_phoneStorageBytes!)
                          : _phoneStorageBytes == null
                              ? 'Unavailable'
                              : _size(_phoneStorageBytes!),
                      onTap: _browsePhoneStorage,
                    )),
                    const SizedBox(width: 10),
                    Expanded(child: _dashboardStorageMetric(
                      icon: Icons.folder_outlined,
                      title: 'Grid storage',
                      value: _size(_totalStorageBytes),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const FoldersScreen()),
                      ),
                    )),
                  ]),
                ],
              ),
            ),
          ),
        if (!widget.favoritesOnly && !widget.recentOnly &&
            _search.text.trim().isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Text(_showStarredRecent ? 'Starred' : 'Recent',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      const Spacer(),
                      SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(value: 'phone', label: Text('Phone')),
                          ButtonSegment(value: 'grid', label: Text('Grid')),
                        ],
                        selected: {_showStarredRecent ? _starredFilter : _recentFilter},
                        onSelectionChanged: (selection) => setState(() {
                          if (_showStarredRecent) {
                            _starredFilter = selection.first;
                          } else {
                            _recentFilter = selection.first;
                          }
                        }),
                      ),
                      PopupMenuButton<String>(
                        tooltip: _showStarredRecent ? 'Starred options' : 'Recent options',
                        onSelected: (value) async {
                          if (value == 'starred') {
                            await _loadAllStarred();
                            if (mounted) setState(() => _showStarredRecent = true);
                          } else if (value == 'recent') {
                            setState(() => _showStarredRecent = false);
                          } else if (value == 'clear') {
                            await _clearRecentActivity();
                          } else if (value == 'refresh') {
                            await _loadRecentDocuments();
                            if (_showStarredRecent) await _loadAllStarred();
                          }
                        },
                        itemBuilder: (_) => _showStarredRecent
                            ? const [
                                PopupMenuItem(value: 'recent', child: Text('Recent')),
                                PopupMenuItem(value: 'refresh', child: Text('Refresh Starred')),
                              ]
                            : const [
                                PopupMenuItem(value: 'clear', child: Text('Clear Recent')),
                                PopupMenuItem(value: 'starred', child: Text('Starred')),
                                PopupMenuItem(value: 'refresh', child: Text('Refresh Recent')),
                              ],
                      ),
                    ]),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 320,
                      child: _showStarredRecent
                          ? _starredFilter == 'phone'
                              ? _phoneStarred.isEmpty
                                  ? const Center(child: Text('No starred Phone PDFs'))
                                  : ListView.separated(
                                      primary: false,
                                      itemCount: _phoneStarred.length,
                                      separatorBuilder: (_, _) => const Divider(height: 1),
                                      itemBuilder: (context, index) =>
                                          _phoneStarredTile(_phoneStarred[index]),
                                    )
                              : _starredRecent.isEmpty
                                  ? const Center(child: Text('No starred Grid PDFs'))
                                  : ListView.separated(
                                      primary: false,
                                      itemCount: _starredRecent.length,
                                      separatorBuilder: (_, _) => const Divider(height: 1),
                                      itemBuilder: (context, index) =>
                                          _recentDocumentTile(_starredRecent[index]),
                                    )
                          : _recentFilter == 'phone'
                              ? _phoneRecent.isEmpty
                                  ? const Center(child: Text('No recent Phone PDFs'))
                                  : ListView.separated(
                                      primary: false,
                                      itemCount: _phoneRecent.length,
                                      separatorBuilder: (_, _) => const Divider(height: 1),
                                      itemBuilder: (context, index) => _phoneRecentTile(_phoneRecent[index]),
                                    )
                              : _gridRecent.isEmpty
                                  ? (!_liveGridRecentLoaded && _cachedGridRecentNames.isNotEmpty
                                      ? ListView.builder(
                                          primary: false,
                                          itemCount: _cachedGridRecentNames.length,
                                          itemBuilder: (context, index) => ListTile(
                                            dense: true,
                                            enabled: false,
                                            leading: const Icon(Icons.picture_as_pdf_outlined),
                                            title: Text('${_cachedGridRecentNames[index]}.pdf',
                                              maxLines: 1, overflow: TextOverflow.ellipsis),
                                            subtitle: const Text('Previous session · verifying PDFs'),
                                          ),
                                        )
                                      : const Center(child: Text('No recent Grid PDFs')))
                                  : ListView.separated(
                                      primary: false,
                                      itemCount: _gridRecent.length,
                                      separatorBuilder: (_, _) => const Divider(height: 1),
                                      itemBuilder: (context, index) => _recentDocumentTile(_gridRecent[index]),
                                    ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (!widget.favoritesOnly && !widget.recentOnly &&
            _search.text.trim().isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Card(
              elevation: 0,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: _showTrash,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Recycle Bin', style: TextStyle(fontWeight: FontWeight.w700)),
                            Text(
                              '$_trashCount PDFs · $_trashFolderCount folders',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (!widget.favoritesOnly && _search.text.trim().isNotEmpty)
          Builder(builder: (context) {
            final matches = _phoneStorageSearchMatches(_search.text);
            final visibleCount = matches.length < _homePhoneSearchVisibleCount
                ? matches.length : _homePhoneSearchVisibleCount;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
                  child: Row(children: [
                    Expanded(child: _homeSearchSourceTab(
                      phone: true,
                      title: 'Phone Storage',
                      count: '${matches.length}',
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: _homeSearchSourceTab(
                      phone: false,
                      title: 'Grid Storage',
                      count: '${_documents.length}${_hasMore ? '+' : ''}',
                    )),
                  ]),
                ),
                if (_homeSearchPhoneSelected) ...[
                  // Background reconciliation must never replace valid rows
                  // with an empty "Scanning..." card.
                  if (matches.isEmpty && _phoneScanLoading)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 10),
                          Flexible(child: Text('Scanning Phone Storage…')),
                        ],
                      ),
                    )
                  else if (matches.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                      child: Text(
                        'No matching PDFs in the scanned Phone Storage locations.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (matches.isNotEmpty)
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      itemCount: visibleCount,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (_, index) => _homePhoneSearchTile(matches[index]),
                    ),
                  if (visibleCount < matches.length)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                      child: TextButton(
                        key: const ValueKey('home-phone-more-results'),
                        onPressed: () => setState(() =>
                            _homePhoneSearchVisibleCount += _homePhoneSearchPageSize),
                        child: Text('Show more Phone PDFs (${matches.length - visibleCount} remaining)'),
                      ),
                    ),
                ] else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Grid Storage · ${_documents.length}${_hasMore ? '+' : ''} matches',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                  ),
              ],
            );
          }),
        if (_importing) const LinearProgressIndicator(),
        if (widget.favoritesOnly || widget.recentOnly ||
            (_search.text.trim().isNotEmpty && !_homeSearchPhoneSelected))
          if (_loading)
            const SizedBox(height: 220, child: Center(child: CircularProgressIndicator()))
        else if (_error != null)
          SizedBox(
            height: 220,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 42),
                    const SizedBox(height: 12),
                    const Text('Could not load documents',
                      style: TextStyle(fontWeight: FontWeight.w600),
                      textAlign: TextAlign.center),
                    const SizedBox(height: 6),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            ),
          )
        else if (_documents.isEmpty)
          if (!widget.favoritesOnly && _search.text.trim().isNotEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 22, 16, 28),
              child: Text('No matching PDFs in Grid Storage.',
                  textAlign: TextAlign.center),
            )
          else
            _emptyState()
        else
          if (_gridView)
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 600 ? 3 : 2;
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: 6,
                    mainAxisSpacing: 6,
                    childAspectRatio: 1.65,
                  ),
                  itemCount: _documents.length + (_loadingMore ? 1 : 0),
                  itemBuilder: (context, index) => index >= _documents.length
                      ? const Center(child: CircularProgressIndicator())
                      : _documentTile(_documents[index]),
                );
              },
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
              itemCount: _documents.length + (_loadingMore ? 1 : 0),
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, index) => index >= _documents.length
                  ? const Padding(
                      padding: EdgeInsets.all(18),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : _documentTile(_documents[index]),
            ),
      ],
          ),
        ),
      ),
    );
  }

  Widget _dashboardStorageMetric({
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
  }) => Material(
    color: const Color(0x66717FBF),
    borderRadius: BorderRadius.circular(18),
    child: InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: const Color(0xFF202A4D), size: 20),
            const SizedBox(height: 8),
            Text(title, style: const TextStyle(color: Color(0xFF202A4D), fontSize: 13)),
            const SizedBox(height: 3),
            Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF10162C), fontSize: 16, fontWeight: FontWeight.w800)),
          ],
        ),
      ),
    ),
  );

  String _normaliseSearchLocation(String value) {
    try {
      return Uri.decodeFull(value).trim().toLowerCase();
    } catch (_) {
      return value.trim().toLowerCase();
    }
  }

  List<Map<String, Object?>> _phoneStorageSearchMatches(String rawQuery) {
    final terms = rawQuery.trim().toLowerCase().split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty).toList(growable: false);
    if (terms.isEmpty) return const [];

    // A PDF already represented by the Grid database must not appear twice
    // when its stored URI points at the same Phone Storage file.
    final gridLocations = _documents
        .map((document) => _normaliseSearchLocation(document.storagePath))
        .where((location) => location.isNotEmpty)
        .toSet();

    return _phoneEntries.where((entry) {
      if (entry['isDirectory'] == true ||
          entry['isInaccessible'] == true ||
          entry['isInaccessibleSummary'] == true) {
        return false;
      }
      final uri = _normaliseSearchLocation(entry['uri'] as String? ?? '');
      if (uri.isEmpty || gridLocations.contains(uri)) return false;

      final name = (entry['name'] as String? ?? '').toLowerCase();
      return terms.every(name.contains);
    }).toList(growable: false)
      ..sort((a, b) {
        final folderA = (a['folderPath'] as String? ?? '').toLowerCase();
        final folderB = (b['folderPath'] as String? ?? '').toLowerCase();
        final folderOrder = folderA.compareTo(folderB);
        if (folderOrder != 0) return folderOrder;
        return (a['name'] as String? ?? '').toLowerCase()
            .compareTo((b['name'] as String? ?? '').toLowerCase());
      });
  }

  Widget _emptyState() => SingleChildScrollView(
    physics: const AlwaysScrollableScrollPhysics(),
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: MediaQuery.sizeOf(context).height * 0.22),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.picture_as_pdf_outlined, size: 48),
              const SizedBox(height: 8),
              Text(widget.favoritesOnly ? 'No starred PDFs yet' : widget.recentOnly ? 'No recently opened PDFs' : 'Your library is empty',
                  style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(widget.recentOnly ? 'Open a PDF and it will appear here.' : 'Import PDF files from your phone to get started.', textAlign: TextAlign.center),
              if (!widget.favoritesOnly && !widget.recentOnly) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _browsePhoneStorage,
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('Browse phone storage'),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );

  Widget _homeSearchSourceTab({
    required bool phone,
    required String title,
    required String count,
  }) {
    final selected = _homeSearchPhoneSelected == phone;
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected ? colors.secondaryContainer : colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: ValueKey(phone ? 'home-search-phone-tab' : 'home-search-grid-tab'),
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          if (selected) return;
          setState(() => _homeSearchPhoneSelected = phone);
          if (_scrollController.hasClients) _scrollController.jumpTo(0);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Row(children: [
            Icon(phone ? Icons.phone_android_outlined : Icons.folder_outlined,
                size: 17, color: selected ? colors.onSecondaryContainer : colors.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: selected ? FontWeight.w700 : FontWeight.w500))),
            const SizedBox(width: 4),
            Text(count, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                color: selected ? colors.onSecondaryContainer : colors.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }

  // Matches the Grid Card/ListTile/thumbnail presentation while delegating
  // every Phone file action to the existing, checksum-safe handlers.
  Widget _homePhoneSearchTile(Map<String, Object?> entry) {
    final name = entry['name'] as String? ?? 'PDF';
    final uri = entry['uri'] as String? ?? '';
    final path = (entry['folderPath'] ?? entry['path'] ?? '').toString();
    final bytes = (entry['sizeBytes'] as num?)?.toInt() ?? 0;
    return Card(
      elevation: 0,
      child: ListTile(
        key: ValueKey('home-phone-pdf-$uri'),
        onTap: () => _openExternalStoragePdf(uri, name),
        leading: DocumentThumbnail(
          documentId: 'phone_$uri',
          storagePath: uri,
          sizeBytes: bytes,
          sourceLastModifiedMillis: thumbnailModifiedMillis(entry['lastModified']),
        ),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${_size(bytes)} · Phone Storage · ${path.isEmpty ? 'Root' : path}',
            maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: PopupMenuButton<String>(
          tooltip: 'Actions for $name',
          onSelected: (action) async {
            if (action == 'share') {
              await _sharePhonePdf(uri, name);
            } else if (action == 'favorite') {
              await _recordExternalFavorite(uri, name);
            } else if (action == 'rename') {
              await _renamePhonePdf(uri, name);
            } else if (action == 'move_phone') {
              await _movePhonePdfWithinPhone(uri, name);
            } else if (action == 'move_grid') {
              await _movePhonePdfToGrid(uri, name);
            } else if (action == 'trash') {
              await _trashPhonePdf(uri, name);
            } else if (action == 'details') {
              await PdfDetailsDialog.showPhone(context, entry);
            } else if (action == 'location') {
              if (!mounted) return;
              await showDialog<void>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('File Location'),
                  content: SelectableText(path.isEmpty ? uri : path),
                  actions: [TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Close'),
                  )],
                ),
              );
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'share', child: Text('Share PDF')),
            PopupMenuItem(value: 'favorite',
              child: Text(_phoneStarredUris.contains(uri)
                  ? 'Remove from Star' : 'Add to Star')),
            const PopupMenuItem(value: 'rename', child: Text('Rename')),
            const PopupMenuItem(value: 'move_phone', child: Text('Move')),
            const PopupMenuItem(value: 'move_grid', child: Text('Move to Grid')),
            const PopupMenuItem(value: 'trash', child: Text('Delete')),
            const PopupMenuItem(value: 'location', child: Text('File Location')),
            const PopupMenuItem(value: 'details', child: Text('Details')),
          ],
        ),
      ),
    );
  }

  Widget _documentTile(DocumentRecord document) {
    final selected = _selectedIds.contains(document.id);
    return Card(
      elevation: 0,
      child: Semantics(
        explicitChildNodes: true,
        label: '${document.name}.pdf, ${_size(document.sizeBytes)}, ${document.isFavorite ? 'starred' : 'not starred'}',
        child: ListTile(
        key: ValueKey(document.id),
        onTap: () => _selectionMode ? _toggleSelected(document) : _open(document),
        onLongPress: () => _startSelection(document),
        leading: _selectionMode
            ? Checkbox(value: selected, onChanged: (_) => _toggleSelected(document))
            : DocumentThumbnail(
                documentId: document.id,
                storagePath: document.storagePath,
                sizeBytes: document.sizeBytes,
              ),
        title: Text('${document.name}.pdf', maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text([
          _size(document.sizeBytes),
          document.categoryName ?? 'Uncategorised',
          if (document.tagNames.isNotEmpty) document.tagNames.join(', '),
          (document.storagePath.startsWith('content://') || document.storagePath.startsWith('file://') || document.storagePath.isNotEmpty) ? 'On this device' : 'File missing',
        ].join(' · ')),
        trailing: _selectionMode ? null : PopupMenuButton<String>(
          tooltip: 'Actions for ${document.name}',
          onSelected: (value) async {
            if (value == 'favorite') {
              final nextFavorite = !document.isFavorite;
              await _repository.setFavorite(document, nextFavorite);
              if (!mounted) return;
              setState(() {
                if (widget.favoritesOnly && !nextFavorite) {
                  _documents.removeWhere((item) => item.id == document.id);
                } else {
                  final index = _documents.indexWhere((item) => item.id == document.id);
                  if (index >= 0) {
                    final current = _documents[index];
                    _documents[index] = DocumentRecord(
                      id: current.id,
                      name: current.name,
                      storagePath: current.storagePath,
                      sizeBytes: current.sizeBytes,
                      createdAt: current.createdAt,
                      isFavorite: nextFavorite,
                      categoryId: current.categoryId,
                      categoryName: current.categoryName,
                      tagNames: current.tagNames,
                      folderId: current.folderId,
                      lastOpenedAt: current.lastOpenedAt,
                      source: current.source,
                    );
                  }
                }
                _starredCount = (_starredCount + (nextFavorite ? 1 : -1)).clamp(0, _totalDocumentCount).toInt();
              });
              await _loadAllStarred();
            } else if (value == 'tags') {
              await _editTags(document);
            } else if (value == 'move') {
              await _moveToFolder(document);
            } else if (value == 'category') {
              await _chooseCategory(document);
            } else if (value == 'rename') {
              await _rename(document);
            } else if (value == 'share') {
              await _share(document);
            } else if (value == 'reminder') {
              await _addReminder(document);
            } else if (value == 'relink') {
              await _relink(document);
            } else if (value == 'trash') {
              await _trash(document);
            } else if (value == 'details') {
              await PdfDetailsDialog.showGrid(context, document);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'share', child: Text('Share PDF')),
            PopupMenuItem(value: 'favorite',
              child: Text(document.isFavorite ? 'Remove from Star' : 'Add to Star')),
            const PopupMenuItem(value: 'category', child: Text('Set category')),
            const PopupMenuItem(value: 'tags', child: Text('Edit tags')),
            const PopupMenuItem(value: 'rename', child: Text('Rename')),
            const PopupMenuItem(value: 'relink', child: Text('Relink PDF')),
            const PopupMenuItem(value: 'move', child: Text('Move to folder')),
            const PopupMenuItem(value: 'trash', child: Text('Move to Recycle Bin')),
            const PopupMenuItem(value: 'details', child: Text('Details')),
          ],
        ),
      ),
    ),
    );
  }

  Widget _recentSourceTag(String label) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      child: Text(label, style: Theme.of(context).textTheme.labelSmall),
    ),
  );

  String _recentDateLabel(DateTime value) {
    final local = value.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final difference = today.difference(day).inDays;
    final time = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    if (difference == 0) return 'Today, $time';
    if (difference == 1) return 'Yesterday, $time';
    return '${local.day.toString().padLeft(2, '0')}-${local.month.toString().padLeft(2, '0')}-${local.year}';
  }

  String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

class _RecentSelectionScreen extends StatefulWidget {
  const _RecentSelectionScreen({
    required this.initialDocument,
    required this.loadItems,
    required this.onOpen,
    required this.onMove,
    required this.onCopy,
    required this.onDelete,
    required this.onShare,
    required this.onRename,
  });

  final DocumentRecord initialDocument;
  final Future<List<DocumentRecord>> Function() loadItems;
  final Future<void> Function(DocumentRecord) onOpen;
  final Future<void> Function(List<DocumentRecord>) onMove;
  final Future<void> Function(List<DocumentRecord>) onCopy;
  final Future<bool> Function(List<DocumentRecord>) onDelete;
  final Future<void> Function(List<DocumentRecord>) onShare;
  final Future<bool> Function(DocumentRecord) onRename;

  @override
  State<_RecentSelectionScreen> createState() => _RecentSelectionScreenState();
}

class _RecentSelectionScreenState extends State<_RecentSelectionScreen> {
  late final Set<String> _selected = {widget.initialDocument.id};
  List<DocumentRecord> _items = [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await widget.loadItems();
      if (mounted) setState(() { _items = items; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<DocumentRecord> get _selectedItems =>
      _items.where((item) => _selected.contains(item.id)).toList(growable: false);

  void _clearSelection() {
    if (_selected.isEmpty) return;
    setState(_selected.clear);
  }

  void _toggleSelection(DocumentRecord item, bool? value) {
    setState(() {
      if (value == true) {
        _selected.add(item.id);
      } else {
        _selected.remove(item.id);
      }
    });
  }

  Future<void> _run(Future<void> Function(List<DocumentRecord>) action) async {
    if (_busy || _selectedItems.isEmpty) return;
    setState(() => _busy = true);
    try {
      await action(_selectedItems);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Action failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteSelected() async {
    if (_busy || _selectedItems.isEmpty) return;
    setState(() => _busy = true);
    try {
      final completed = await widget.onDelete(_selectedItems);
      if (completed && mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _more() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(child: ListView(shrinkWrap: true, children: [
        const ListTile(title: Text('More actions')),
        ListTile(
          leading: const Icon(Icons.drive_file_rename_outline),
          title: const Text('Rename'),
          onTap: () => Navigator.pop(ctx, 'rename'),
        ),
      ])),
    );
    if (choice == 'rename' && _selectedItems.length == 1 && mounted) {
      final renamed = await widget.onRename(_selectedItems.single);
      if (renamed && mounted) Navigator.of(context).pop('rename');
    }
  }

  Widget _actionButton(IconData icon, String label, VoidCallback onPressed) =>
      Expanded(
        child: TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: _busy || _selected.isEmpty ? null : onPressed,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 22),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label, style: const TextStyle(fontSize: 10)),
            ),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: _selected.isEmpty,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && _selected.isNotEmpty && mounted) _clearSelection();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(_selected.isEmpty ? 'Recent' : '${_selected.length} selected'),
        leading: IconButton(
          icon: Icon(_selected.isEmpty ? Icons.arrow_back : Icons.close),
          onPressed: _selected.isEmpty
              ? () => Navigator.of(context).pop()
              : _clearSelection,
        ),
        actions: [
          TextButton(
            onPressed: () => setState(() {
              if (_selected.length == _items.length) {
                _selected.clear();
              } else {
                _selected.addAll(_items.map((item) => item.id));
              }
            }),
            child: const Text('Select all'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = _items[index];
                return ListTile(
                  onTap: _selected.isEmpty ? () => widget.onOpen(item) : null,
                  leading: DocumentThumbnail(
                    documentId: item.id,
                    storagePath: item.storagePath,
                    sizeBytes: item.sizeBytes,
                  ),
                  title: Text('${item.name}.pdf',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${(item.sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB',
                  ),
                  onLongPress: () {
                    if (_selected.isEmpty) {
                      setState(() => _selected.add(item.id));
                    }
                  },
                  trailing: _selected.isEmpty
                      ? null
                      : Checkbox(
                          value: _selected.contains(item.id),
                          onChanged: (value) => _toggleSelection(item, value),
                        ),
                );
              },
            ),
      bottomNavigationBar: _selected.isEmpty
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
                ),
                child: Row(children: [
                  _actionButton(Icons.drive_file_move_outline, 'Move', () => _run(widget.onMove)),
                  _actionButton(Icons.copy_outlined, 'Copy', () => _run(widget.onCopy)),
                  _actionButton(Icons.delete_outline, 'Delete', _deleteSelected),
                  _actionButton(Icons.share_outlined, 'Share', () => _run(widget.onShare)),
                  _actionButton(Icons.more_vert, 'More', _more),
                ]),
              ),
            ),
    ),
  );
}

class _PhoneRecentSelectionScreen extends StatefulWidget {
  const _PhoneRecentSelectionScreen({
    required this.items,
    required this.initialUri,
    required this.onOpen,
    required this.onShare,
    required this.onDelete,
  });

  final List<Map<String, Object?>> items;
  final String initialUri;
  final Future<void> Function(Map<String, Object?>) onOpen;
  final Future<void> Function(List<Map<String, Object?>>) onShare;
  final Future<bool> Function(List<Map<String, Object?>>) onDelete;

  @override
  State<_PhoneRecentSelectionScreen> createState() => _PhoneRecentSelectionScreenState();
}

class _PhoneRecentSelectionScreenState extends State<_PhoneRecentSelectionScreen> {
  late final Set<String> _selected = {widget.initialUri};
  bool _busy = false;

  List<Map<String, Object?>> get _chosen => widget.items
      .where((item) => _selected.contains(item['uri']))
      .toList(growable: false);

  void _clearSelection() {
    if (_selected.isEmpty) return;
    setState(_selected.clear);
  }

  void _toggleSelection(String uri, bool? value) {
    setState(() {
      if (value == true) {
        _selected.add(uri);
      } else {
        _selected.remove(uri);
      }
    });
  }

  Future<void> _run(Future<void> Function(List<Map<String, Object?>>) action) async {
    if (_busy || _chosen.isEmpty) return;
    setState(() => _busy = true);
    try {
      await action(_chosen);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Action failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteSelected() async {
    if (_busy || _chosen.isEmpty) return;
    setState(() => _busy = true);
    try {
      final completed = await widget.onDelete(_chosen);
      if (completed && mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _actionButton(IconData icon, String label, VoidCallback onPressed) =>
      Expanded(
        child: TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: _busy || _selected.isEmpty ? null : onPressed,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 22),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label, style: const TextStyle(fontSize: 10)),
            ),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: _selected.isEmpty,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && _selected.isNotEmpty && mounted) _clearSelection();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(_selected.isEmpty ? 'Recent' : '${_selected.length} selected'),
        leading: IconButton(
          icon: Icon(_selected.isEmpty ? Icons.arrow_back : Icons.close),
          onPressed: _selected.isEmpty
              ? () => Navigator.of(context).pop()
              : _clearSelection,
        ),
        actions: [
          TextButton(
            onPressed: () => setState(() {
              if (_selected.length == widget.items.length) {
                _selected.clear();
              } else {
                _selected.addAll(widget.items.map((item) => item['uri'] as String));
              }
            }),
            child: const Text('Select all'),
          ),
        ],
      ),
      body: ListView.separated(
        itemCount: widget.items.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final item = widget.items[index];
          final uri = item['uri'] as String;
          return ListTile(
            onTap: _selected.isEmpty ? () => widget.onOpen(item) : null,
            leading: DocumentThumbnail(
              documentId: 'phone_recent_$uri',
              storagePath: uri,
              sizeBytes: (item['sizeBytes'] as num?)?.toInt() ?? 0,
            ),
            title: Text(item['name'] as String? ?? 'PDF'),
            subtitle: Text('Phone · ${item['openedAt'] ?? ''}'),
            onLongPress: () {
              if (_selected.isEmpty) {
                setState(() => _selected.add(uri));
              }
            },
            trailing: _selected.isEmpty
                ? null
                : Checkbox(
                    value: _selected.contains(uri),
                    onChanged: (value) => _toggleSelection(uri, value),
                  ),
          );
        },
      ),
      bottomNavigationBar: _selected.isEmpty
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
                ),
                child: Row(children: [
                  _actionButton(Icons.drive_file_move_outline, 'Move', _messageDisabled),
                  _actionButton(Icons.copy_outlined, 'Copy', _messageDisabled),
                  _actionButton(Icons.delete_outline, 'Delete', _deleteSelected),
                  _actionButton(Icons.share_outlined, 'Share', () => _run(widget.onShare)),
                  _actionButton(Icons.more_vert, 'More', _messageDisabled),
                ]),
              ),
            ),
    ),
  );

  void _messageDisabled() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Use the Phone folder browser for file-management actions.')),
    );
  }
}
