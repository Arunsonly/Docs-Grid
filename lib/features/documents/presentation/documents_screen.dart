import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/document_repository.dart';
import '../../../core/storage/storage_location_service.dart';
import '../../categories/data/category_repository.dart';
import '../../folders/data/folder_repository.dart';
import '../../tools/document_tools_service.dart';
import 'document_pdf_viewer_screen.dart';
import 'document_thumbnail.dart';
import 'phone_storage_browser_screen.dart';
import '../../folders/presentation/folders_screen.dart';
import '../../reminders/data/reminder_repository.dart';

class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key, this.favoritesOnly = false, this.recentOnly = false, this.phoneOnly = false});
  final bool favoritesOnly;
  final bool recentOnly;
  final bool phoneOnly;

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen>
    with WidgetsBindingObserver {
  final _repository = DocumentRepository();
  final _categoryRepository = CategoryRepository();
  final _folderRepository = FolderRepository();
  final _tools = DocumentToolsService();
  final _search = TextEditingController();
  final _scrollController = ScrollController();
  List<DocumentRecord> _documents = [];
  bool _loading = true;
  final bool _importing = false;
  bool _searchInsideText = false;
  bool _gridView = false;
  int _totalStorageBytes = 0;
  int _totalDocumentCount = 0;
  int _starredCount = 0;
  int? _phoneStorageBytes;
  bool _phoneScanLoading = false;
  bool _phoneScanCompleted = false;
  StreamSubscription<void>? _storageChangesSubscription;
  Timer? _phoneRefreshDebounce;
  bool _phoneScanPending = false;
  int _trashCount = 0;
  List<Map<String, Object?>> _phoneRecent = [];
  List<DocumentRecord> _gridRecent = [];
  bool _showStarredRecent = false;
  List<DocumentRecord> _starredRecent = [];
  String _recentFilter = 'grid';
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
    WidgetsBinding.instance.addObserver(this);
    _storageChangesSubscription =
        StorageLocationService.instance.storageChanges.listen(
      (_) => _schedulePhoneStorageRefresh(),
      onError: (_) {
        // Provider change events are best-effort; resume reconciliation remains.
      },
    );
    if (!widget.phoneOnly) {
      _load();
      _loadViewPreference();
      _loadTrashSummary();
      _loadRecentDocuments();
    }
    _search.addListener(_onSearchChanged);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.phoneOnly) {
        // Show the Phone tab in place; do not push a second page after scanning.
        _scanPhoneStorage(openBrowser: false);
      } else if (!widget.favoritesOnly && !widget.recentOnly) {
        _scanPhoneStorage(openBrowser: false);
      }
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
    if (_scrollController.position.extentAfter < 600) _loadMore();
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 280), () {
      if (mounted) _load();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _schedulePhoneStorageRefresh();
    }
  }

  void _schedulePhoneStorageRefresh() {
    if (!mounted || widget.favoritesOnly || widget.recentOnly) return;
    _phoneRefreshDebounce?.cancel();
    _phoneRefreshDebounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted) unawaited(_scanPhoneStorage(openBrowser: false));
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _storageChangesSubscription?.cancel();
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
    final generation = ++_loadGeneration;
    if (mounted) setState(() { _loading = true; _loadingMore = false; });
    // Run the small first page and dashboard aggregates concurrently. Render
    // the document rows as soon as the page is ready; never make the first
    // useful screen wait for a full-library summary query.
    final summaryFuture = _repository.dashboardSummary();
    try {
      if (_searchInsideText && _search.text.trim().isNotEmpty) {
        final allDocsFuture = _repository.list(recentOnly: widget.recentOnly);
        final matchesFuture = _tools.searchText(_search.text);
        final allDocs = await allDocsFuture;
        final matches = await matchesFuture;
        final matchedIds = matches.map((row) => row['id'] as String).toSet();
        final docs = allDocs.where((document) =>
          (!widget.favoritesOnly || document.isFavorite) &&
          matchedIds.contains(document.id)).toList();
        if (!mounted || generation != _loadGeneration) return;
        setState(() {
          _documents = docs;
          _nextCursor = null;
          _hasMore = false;
          _loading = false;
          _error = null;
        });
      } else {
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
      }
      // Summary is secondary UI. Update it when ready without delaying the
      // first page, and ignore stale completions after a newer refresh.
      try {
        final summary = await summaryFuture;
        if (!mounted || generation != _loadGeneration) return;
        setState(() {
          _totalStorageBytes = summary.totalBytes;
          _totalDocumentCount = summary.documentCount;
          _starredCount = summary.favoriteCount;
        });
      } catch (_) {
        // A summary failure must not blank a successfully loaded PDF list.
      }
    } catch (error) {
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
    try {
      final trashed = await _repository.listTrash();
      if (!mounted) return;
      setState(() {
        _trashCount = trashed.length;
      });
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
    });
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
    // Reuse the dashboard's completed scan. Opening its detailed browser must
    // not walk the whole storage tree a second time.
    if (_phoneScanCompleted) {
      await _showRecursiveStoragePdfs('Internal Storage', _phoneEntries);
      return;
    }
    await _scanPhoneStorage(openBrowser: true);
  }

  Future<bool> _restorePhoneStorageIndexCache(List<Map<String, String>> roots) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('docsgrid_phone_storage_index_v1');
      if (raw == null) return false;
      final decoded = jsonDecode(raw);
      final signature = roots.map((root) => root['uri']!).join('|');
      if (decoded is! Map || decoded['rootSignature'] != signature ||
          decoded['entries'] is! List) return false;
      final cached = (decoded['entries'] as List).whereType<Map>()
          .map((entry) => Map<String, Object?>.from(entry)).toList(growable: false);
      if (!mounted || cached.isEmpty) return false;
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
      await prefs.setString('docsgrid_phone_storage_index_v1', jsonEncode({
        'rootSignature': roots.map((root) => root['uri']!).join('|'),
        'mediaStoreVolumes': mediaStoreVolumes,
        'entries': entries,
      }));
    } catch (_) {
      // Optional cache; never compromise the live filesystem listing.
    }
  }

  Future<void> _scanPhoneStorage({required bool openBrowser}) async {
    final storage = StorageLocationService.instance;
    if (_phoneScanLoading) {
      _phoneScanPending = true;
      return;
    }
    if (mounted) setState(() { _phoneScanLoading = true; _phoneScanCompleted = false; });
    try {
      if (Platform.isAndroid) {
        try {
          final usage = await storage.phoneStorageUsage();
          if (mounted) setState(() => _phoneStorageBytes = usage['usedBytes']);
        } catch (_) {
          // StatFs is supplementary; PDF browsing remains available.
        }
      }
      if (Platform.isAndroid && !await storage.hasAllFilesAccess()) {
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
      final roots = await storage.accessibleStorageRoots();
      if (roots.isEmpty) {
        if (mounted) setState(() {
          _phoneEntries = [];
          _phoneScanCompleted = true;
        });
        return;
      }

      // The cached tree is rendered immediately. MediaStore then supplies a
      // fast current index for shared volumes, including removable volumes.
      final cacheRestored = await _restorePhoneStorageIndexCache(roots);
      var mediaStoreComplete = false;
      var mediaStoreVolumes = <String, Object?>{};
      final entries = <Map<String, Object?>>[];
      final seen = <String>{};

      if (Platform.isAndroid && await storage.hasAllFilesAccess()) {
        try {
          final index = await storage.queryPhonePdfIndex();
          final indexed = index['entries'] as List<Map<String, Object?>>;
          final complete = index['complete'] == true;
          if (complete) {
            mediaStoreComplete = true;
            mediaStoreVolumes =
                Map<String, Object?>.from(index['volumes'] as Map);
            entries.addAll(indexed);
            for (final item in indexed) {
              final uri = item['uri'] as String? ?? '';
              if (uri.isNotEmpty) seen.add(uri);
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
          final label = index == 0 ? 'Internal' : root['name']!;
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
        if (!cacheRestored) setState(() => _phoneEntries = firstLevelEntries);
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
            Platform.isAndroid && await storage.hasAllFilesAccess()) {
          // Native file-tree recursion is the safe fallback for failed volumes.
        }
        final label = index == 0 ? 'Internal' : root['name']!;
        try {
          final found = await storage.listStorageTreeRecursively(
            uri,
            rootLabel: label,
            includeEmptyFolders: false,
          );
          for (final item in found) {
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
      if (mediaStoreVolumes.isNotEmpty) {
        await _persistPhoneStorageIndexCache(
          roots,
          entries,
          mediaStoreVolumes: mediaStoreVolumes,
        );
      } else {
        await _persistPhoneStorageIndexCache(roots, entries);
      }
      setState(() {
        _phoneEntries=entries;
        _phoneScanCompleted = true;
      });
      if (openBrowser && !widget.phoneOnly) {
        await _showRecursiveStoragePdfs('Internal Storage', entries);
      }
      if(inaccessibleRoots>0 && mounted) _message('$inaccessibleRoots granted location(s) could not be read; they were not marked empty.');
    } catch(error) {
      if (mounted) {
        setState(() {
          _phoneEntries = [];
          _phoneScanCompleted = false;
        });
        _message('Phone Storage scan failed; inaccessible locations were not marked empty: $error');
      }
    } finally {
      if (mounted) setState(() => _phoneScanLoading = false);
      if (_phoneScanPending && mounted) {
        _phoneScanPending = false;
        _schedulePhoneStorageRefresh();
      }
    }
  }

  Future<void> _showRecursiveStoragePdfs(String rootName, List<Map<String, Object?>> entries, {String initialPath = ''}) async {
    if (!mounted) return;
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => PhoneStorageBrowserScreen(
        rootName: rootName, entries: entries, onOpenPdf: _openExternalStoragePdf,
        onMovePdf: _movePhonePdfToGrid,
        onRenamePdf: _renamePhonePdf,
        onSharePdf: _sharePhonePdf,
        onTrashPdf: _trashPhonePdf,
        initialPath: initialPath,
      ),
    ));
  }

  Future<void> _loadAllStarred() async {
    try {
      final items = await _repository.listAllStarred();
      if (mounted) setState(() => _starredRecent = items);
    } catch (error) {
      if (mounted) _message('Could not load Starred PDFs: $error');
    }
  }

  Future<void> _clearRecentActivity() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('docsgrid_phone_recent_v1');
      await _repository.clearOpenedHistory();
      if (!mounted) return;
      setState(() => _phoneRecent = []);
      await _loadRecentDocuments();
      if (_showStarredRecent) await _loadAllStarred();
      if (mounted) _message('Recent cleared. PDF files were not deleted.');
    } catch (error) {
      if (mounted) _message('Could not clear Recent: $error');
    }
  }

  Future<List<DocumentRecord>> _loadAllRecentGrid() =>
      // The repository caps this query at 100 rows. Requesting 100,000 throws
      // and used to leave Recent selection looking blank.
      _repository.recentActivity(limit: 100);

  List<PopupMenuEntry<String>> _phoneRecentMenu(Map<String, Object?> item) => [
    const PopupMenuItem(value: 'share', child: Text('Share PDF')),
    const PopupMenuItem(value: 'favorite', child: Text('Add to Star')),
    const PopupMenuItem(value: 'category', child: Text('Set category')),
    const PopupMenuItem(value: 'tags', child: Text('Edit tags')),
    const PopupMenuItem(value: 'rename', child: Text('Rename')),
    const PopupMenuItem(value: 'move', child: Text('Move to folder')),
    const PopupMenuItem(value: 'trash', child: Text('Move to Recycle Bin')),
  ];

  Future<void> _handlePhoneRecentAction(Map<String, Object?> item, String action) async {
    final uri = item['uri'] as String? ?? '';
    final name = item['name'] as String? ?? 'PDF';
    if (action == 'share') {
      await _sharePhonePdf(uri, name);
    } else if (action == 'favorite') {
      await _recordExternalFavorite(uri, name);
    } else if (action == 'trash') {
      await _trashPhonePdf(uri, name);
    } else {
      _message('This Phone PDF action is available from the Phone folder browser.');
    }
  }

  Future<void> _recordExternalFavorite(String uri, String name) async {
    _message('Phone files can be starred after importing them into Grid.');
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
        final moved = await _repository.moveExternalPdfToTrash(
          sourceUri: uri,
          displayName: name,
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
    if (mounted) {
      _message(
        'Moved ${movedUris.length} of ${chosen.length} PDFs to Recycle Bin'
        '${failed > 0 ? ' · $failed kept' : ''}',
      );
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
    final activity = document.lastOpenedAt != null
        ? 'Opened'
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
  ];

  Future<void> _handleRecentAction(DocumentRecord document, String action) async {
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
    final action = await Navigator.of(context).push<String>(MaterialPageRoute(
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
    if (action == 'rename' && mounted) {
      _message('Rename completed.');
    }
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
    if (mounted) _message('Moved ${result['moved']} of ${selected.length} PDFs');
  }

  Future<void> _bulkCopyDocuments(List<DocumentRecord> selected) async {
    var copied = 0;
    final failures = <String>[];
    for (final document in selected) {
      try {
        await _repository.copyDocument(document, targetFolderId: document.folderId);
        copied++;
      } catch (error) {
        failures.add('${document.name}: $error');
      }
    }
    if (mounted) _message('Copied $copied of ${selected.length} PDFs'
        '${failures.isEmpty ? '' : ' · ${failures.length} failed'}');
  }

  Future<bool> _bulkDeleteDocuments(List<DocumentRecord> selected) async {
    final confirmed = await _confirmMoveToRecycleBin(
      count: selected.length,
      details: 'The selected PDFs will be hidden from Recent and moved to DocsGrid Recycle Bin. They can be restored later.',
    );
    if (!confirmed) return false;
    await _repository.moveManyToTrash(selected);
    if (mounted) {
      _message('Moved ${selected.length} PDFs to Recycle Bin');
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

  Widget _phoneRecentTile(Map<String, Object?> item) {
    final name = item['name'] as String? ?? 'PDF';
    final uri = item['uri'] as String? ?? '';
    final openedAt = DateTime.tryParse(item['openedAt']?.toString() ?? '');
    return ListTile(
      key: ValueKey('phone-recent-$uri'),
      dense: true,
      leading: DocumentThumbnail(
        documentId: 'phone_recent_$uri',
        storagePath: uri,
        sizeBytes: (item['sizeBytes'] as num?)?.toInt() ?? 0,
      ),
      title: Row(children: [
        Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 6),
        _recentSourceTag('Phone'),
      ]),
      subtitle: Text('Opened · ${_recentDateLabel(openedAt ?? DateTime.now())}'),
      onTap: () => _openExternalStoragePdf(uri, name),
      onLongPress: () => _openPhoneRecentSelection(item),
      trailing: PopupMenuButton<String>(
        tooltip: 'Actions for $name',
        onSelected: (action) => _handlePhoneRecentAction(item, action),
        itemBuilder: (_) => _phoneRecentMenu(item),
      ),
    );
  }

  Future<void> _loadRecentDocuments() async {
    try {
      // Include both opened documents and newly added documents. The list
      // is capped at 20 so the dashboard's Recent panel can scroll independently.
      final recentDocuments = await _repository.recentActivity(limit: 20);
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
      if (!mounted) return;
      setState(() {
        _gridRecent = recentDocuments;
        _phoneRecent = phone.take(20).toList(growable: false);
      });
    } catch (_) {
      // Recent metadata is optional and must not block the dashboard.
    }
  }

  Future<void> _recordPhoneRecent(String uri, String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList('docsgrid_phone_recent_v1') ?? <String>[];
      final recent = <Map<String, Object?>>[];
      for (final item in saved) {
        try {
          final decoded = jsonDecode(item);
          if (decoded is Map && decoded['uri'] != uri) {
            recent.add(Map<String, Object?>.from(decoded));
          }
        } catch (_) {}
      }
      final matchingEntries = _phoneEntries.where((entry) => entry['uri'] == uri).toList();
      final bytes = matchingEntries.isEmpty
          ? 0
          : (matchingEntries.first['sizeBytes'] as num?)?.toInt() ?? 0;
      recent.insert(0, {
        'uri': uri,
        'name': name,
        'sizeBytes': bytes,
        'openedAt': DateTime.now().toUtc().toIso8601String(),
      });
      final limited = recent.take(20).toList(growable: false);
      await prefs.setStringList('docsgrid_phone_recent_v1',
          limited.map((item) => jsonEncode(item)).toList());
      if (mounted) setState(() => _phoneRecent = limited);
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
    final failureSummary = failures.isEmpty ? '' : ' · ${failures.length} failed';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Moved ${result['moved']} of ${selected.length} PDFs$failureSummary'),
    ));
  }

  Future<void> _open(DocumentRecord document) async {
    final isProviderUri = document.storagePath.startsWith('content://') ||
        document.storagePath.startsWith('file://');
    File? stagedProviderFile;
    late final String viewerPath;
    try {
      if (isProviderUri) {
        // Stage provider-backed content with native streaming I/O; never read
        // the entire PDF into Dart memory before the viewer starts.
        final temp = await getTemporaryDirectory();
        stagedProviderFile = File(p.join(
          temp.path,
          'docsgrid_view_${DateTime.now().microsecondsSinceEpoch}.pdf',
        ));
        await StorageLocationService.instance.copyPdfToPath(
          sourceUri: document.storagePath,
          destinationPath: stagedProviderFile.path,
        );
        viewerPath = stagedProviderFile.path;
      } else {
        final localFile = File(document.storagePath);
        if (!await localFile.exists()) {
          if (mounted) _message('PDF file is missing from local storage.');
          return;
        }
        viewerPath = localFile.path;
      }
      await _repository.markOpened(document);
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => DocumentPdfViewerScreen(
            filePath: viewerPath,
            title: '${document.name}.pdf',
          ),
        ),
      );
      await _patchDocument(document.id);
      await _loadRecentDocuments();
    } catch (error) {
      if (mounted) {
        _message('Could not open PDF in the fast viewer: $error');
        // Keep an OS-viewer fallback for files that a native PDF renderer
        // cannot decode (for example, unsupported encryption).
        if (isProviderUri) {
          try {
            await StorageLocationService.instance.openPdf(document.storagePath);
          } catch (fallbackError) {
            _message('External PDF viewer also failed: $fallbackError');
          }
        } else {
          final result = await OpenFilex.open(document.storagePath);
          if (mounted && result.type != ResultType.done) {
            _message(result.message.isEmpty ? 'No PDF viewer is available.' : result.message);
          }
        }
      }
    } finally {
      if (stagedProviderFile != null) {
        try {
          if (await stagedProviderFile.exists()) await stagedProviderFile.delete();
        } catch (_) {
          // Do not let cache cleanup mask the viewer outcome.
        }
      }
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PDF relinked and verified successfully.')),
        );
      }
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reminder saved for this PDF.')));
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save reminder: $error')));
    }
  }

  Future<void> _showTrash() async {
    var trashed = await _repository.listTrash();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refreshDialog) => AlertDialog(
          title: const Text('Recycle Bin'),
          content: SizedBox(
            width: double.maxFinite,
            child: trashed.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text('Recycle Bin is empty.'),
                  )
                : SizedBox(
                    height: 340,
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: trashed.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final document = trashed[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.picture_as_pdf_outlined),
                          title: Text('${document.name}.pdf',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: const Text('PDF moved to Recycle Bin'),
                          trailing: PopupMenuButton<String>(
                            onSelected: (action) async {
                              if (action == 'restore') {
                                await _repository.restoreFromTrash(document);
                                refreshDialog(() => trashed.removeAt(index));
                                await _load();
                              } else if (action == 'delete') {
                                final confirmed = await showDialog<bool>(
                                  context: dialogContext,
                                  builder: (confirmContext) => AlertDialog(
                                    title: const Text('Delete permanently?'),
                                    content: Text('${document.name}.pdf will be erased from this device.'),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(confirmContext, false),
                                        child: const Text('Cancel'),
                                      ),
                                      FilledButton(
                                        onPressed: () => Navigator.pop(confirmContext, true),
                                        child: const Text('Delete'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed == true) {
                                  await _repository.permanentlyDelete(document);
                                  refreshDialog(() => trashed.removeAt(index));
                                  await _load();
                                }
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'restore', child: Text('Restore')),
                              PopupMenuItem(value: 'delete', child: Text('Delete permanently')),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
    await _loadTrashSummary();
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
      final moved = await _repository.moveExternalPdfToTrash(
        sourceUri: uri,
        displayName: name,
      );
      if (!mounted) return false;
      if (moved) {
        _message('PDF moved to Recycle Bin.');
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
      await StorageLocationService.instance.renamePdf(
        uri: uri,
        name: clean.toLowerCase().endsWith('.pdf') ? clean : '$clean.pdf',
      );
      if (!mounted) return false;
      _message('PDF renamed.');
      await _scanPhoneStorage(openBrowser: false);
      await _refreshDashboardSummary();
      return true;
    } catch (error) {
      if (mounted) _message('Could not rename PDF: $error');
      return false;
    }
  }

  Future<void> _sharePhonePdf(String uri, String name) async {
    try {
      await _tools.shareStoredPdf(uri, name);
    } catch (error) {
      if (mounted) _message('Could not share PDF: $error');
    }
  }

  Future<bool> _movePhonePdfToGrid(String uri, String name) async {
    var folders = await _folderRepository.allFoldersWithPaths();
    var selectedFolderId = '';
    final destination = await showDialog<String?>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: const Text('Move PDF to Grid'),
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
    if (destination == null) return false;
    try {
      final result = await _repository.moveExternalPdfToGrid(
        sourceUri: uri,
        displayName: name,
        targetFolderId: destination.isEmpty ? null : destination,
      );
      if (!mounted) return false;
      if (result.added == 1) {
        _message('Moved $name to Grid.');
      } else if (result.duplicates > 0) {
        _message('This PDF already exists in Grid. The Phone original was kept.');
      }
      await _scanPhoneStorage(openBrowser: false);
      await _load();
      await _refreshDashboardSummary();
      return result.added == 1;
    } catch (error) {
      if (mounted) _message('Could not move $name. The Phone original was kept: $error');
      return false;
    }
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
        rootName: 'Internal Storage',
        entries: _phoneEntries,
        onOpenPdf: _openExternalStoragePdf,
        onMovePdf: _movePhonePdfToGrid,
        onRenamePdf: _renamePhonePdf,
        onSharePdf: _sharePhonePdf,
        onTrashPdf: _trashPhonePdf,
        embedded: true,
        isLoading: _phoneScanLoading,
        onRefresh: () => _scanPhoneStorage(openBrowser: true),
      );
    }
    return PopScope<void>(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _selectionMode && mounted) {
          _clearSelection();
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
                      hintText: _searchInsideText ? 'Search text inside PDFs' : 'Search PDF names',
                      prefixIcon: PopupMenuButton<String>(
                        tooltip: 'Choose search type',
                        icon: const Icon(Icons.search),
                        onSelected: (value) {
                          setState(() => _searchInsideText = value == 'text');
                          _load();
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(value: 'name', child: Row(children: [Icon(_searchInsideText ? Icons.circle_outlined : Icons.check_circle, size: 18), const SizedBox(width: 8), const Text('File name') ])),
                          PopupMenuItem(value: 'text', child: Row(children: [Icon(_searchInsideText ? Icons.check_circle : Icons.circle_outlined, size: 18), const SizedBox(width: 8), const Text('Text inside PDF') ])),
                        ],
                      ),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(tooltip: 'Clear search', onPressed: _search.clear, icon: const Icon(Icons.close)),
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
        if (!widget.favoritesOnly && !widget.recentOnly)
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
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: _dashboardStorageMetric(
                      icon: Icons.phone_android_outlined,
                      title: 'Phone storage',
                      value: _phoneStorageBytes == null
                          ? 'Permission needed'
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
        if (!widget.favoritesOnly && !widget.recentOnly)
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
                      if (!_showStarredRecent)
                        SegmentedButton<String>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(value: 'phone', label: Text('Phone')),
                            ButtonSegment(value: 'grid', label: Text('Grid')),
                          ],
                          selected: {_recentFilter},
                          onSelectionChanged: (selection) =>
                              setState(() => _recentFilter = selection.first),
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
                          ? _starredRecent.isEmpty
                              ? const Center(child: Text('No starred PDFs'))
                              : ListView.separated(
                                  primary: false,
                                  itemCount: _starredRecent.length,
                                  separatorBuilder: (_, _) => const Divider(height: 1),
                                  itemBuilder: (context, index) => _recentDocumentTile(_starredRecent[index]),
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
                                  ? const Center(child: Text('No recent Grid PDFs'))
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
        if (!widget.favoritesOnly && !widget.recentOnly)
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
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('$_trashCount PDFs', style: Theme.of(context).textTheme.titleMedium),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (!widget.favoritesOnly && !_searchInsideText && _search.text.trim().isNotEmpty)
          Builder(builder: (context) {
            final matches = _phoneStorageSearchMatches(_search.text);
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        'Phone Storage · ${matches.length} matches',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    if (_phoneScanLoading)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: Row(
                          children: [
                            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                            SizedBox(width: 10),
                            Text('Scanning Phone Storage…'),
                          ],
                        ),
                      )
                    else if (matches.isEmpty)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                        child: Text('No matching PDFs in the scanned Phone Storage locations.'),
                      )
                    else
                      SizedBox(
                        height: (matches.length.clamp(1, 4) * 64).toDouble(),
                        child: ListView.builder(
                          itemCount: matches.length,
                          itemBuilder: (context, index) {
                            final item = matches[index];
                            final name = item['name'] as String? ?? 'PDF';
                            final uri = item['uri'] as String? ?? '';
                            final folder = item['folderPath'] as String? ?? '';
                            final bytes = (item['sizeBytes'] as num?)?.toInt() ?? 0;
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.picture_as_pdf_outlined),
                              title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                'Phone Storage · ${folder.isEmpty ? 'Root' : folder} · ${_size(bytes)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => _openExternalStoragePdf(uri, name),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            );
          }),
        if (!widget.favoritesOnly && !_searchInsideText && _search.text.trim().isNotEmpty)
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
        if (_importing) const LinearProgressIndicator(),
        if (widget.favoritesOnly || widget.recentOnly || _search.text.trim().isNotEmpty)
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
      final folder = (entry['folderPath'] as String? ?? '').toLowerCase();
      final searchable = '$name $folder';
      return terms.every(searchable.contains);
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
            const PopupMenuItem(value: 'trash', child: Text('Move to Recycle Bin')),
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
