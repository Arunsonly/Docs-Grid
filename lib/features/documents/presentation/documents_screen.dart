import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/document_repository.dart';
import '../../../core/storage/storage_location_service.dart';
import '../../categories/data/category_repository.dart';
import '../../folders/data/folder_repository.dart';
import '../../tools/document_tools_service.dart';
import '../../tools/document_tools_screen.dart' show DocumentToolsScreen;
import 'document_pdf_viewer_screen.dart';
import 'phone_storage_browser_screen.dart';
import '../../folders/presentation/folders_screen.dart';
import '../../reminders/data/reminder_repository.dart';

class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key, this.favoritesOnly = false, this.recentOnly = false});
  final bool favoritesOnly;
  final bool recentOnly;

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
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
  int _totalStorageBytes = 0;
  int _totalDocumentCount = 0;
  int _starredCount = 0;
  int? _phonePdfCount;
  int? _phoneStorageBytes;
  int _trashCount = 0;
  int _trashBytes = 0;
  List<Map<String, Object?>> _phoneFolders = [];
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
    _load();
    _loadTrashSummary();
    _search.addListener(_onSearchChanged);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.favoritesOnly && !widget.recentOnly) _scanPhoneStorage(openBrowser: false);
    });
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
  void dispose() {
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
        _trashBytes = trashed.fold<int>(0, (sum, item) => sum + item.sizeBytes);
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

  Future<void> _browsePhoneStorage() => _scanPhoneStorage(openBrowser: true);

  Future<void> _scanPhoneStorage({required bool openBrowser}) async {
    final storage = StorageLocationService.instance;
    try {
      if (Platform.isAndroid && !await storage.hasAllFilesAccess()) {
        final granted = await storage.accessibleStorageRoots();
        if (granted.isEmpty) {
          if (mounted) setState(() { _phonePdfCount = null; _phoneStorageBytes = null; });
          if (openBrowser && mounted) {
            await storage.requestAllFilesAccess();
            _message('Grant Android storage access or a SAF location. No folder picker was opened.');
          }
          return;
        }
      }
      final roots = await storage.accessibleStorageRoots();
      if (roots.isEmpty) {
        if (mounted) setState(() { _phonePdfCount = null; _phoneStorageBytes = null; });
        return;
      }
      final entries = <Map<String,Object?>>[], seen = <String>{};
      var inaccessibleRoots=0;
      for(final root in roots) {
        try {
          final found=await storage.listStorageTreeRecursively(root['uri']!,
            rootLabel:root['name']!, includeEmptyFolders:false);
          for(final item in found) {
            final uri=item['uri'] as String? ?? '';
            if(item['isDirectory']!=true && uri.isNotEmpty && !seen.add(uri)) continue;
            entries.add(item);
          }
        } catch(error) {
          inaccessibleRoots++;
          entries.add({'name':root['name']!,'uri':root['uri']!,'folderPath':'',
            'isDirectory':true,'isInaccessible':true,'accessError':error.toString()});
        }
      }
      final pdfs=entries.where((e)=>e['isDirectory']!=true).toList();
      final bytes=pdfs.fold<int>(0,(sum,e)=>sum+((e['sizeBytes'] as num?)?.toInt()??0));
      if(!mounted)return;
      setState(() {
        _phonePdfCount = inaccessibleRoots == roots.length ? null : pdfs.length;
        _phoneStorageBytes = inaccessibleRoots == roots.length ? null : bytes;
        _phoneEntries=entries;
        _phoneFolders=entries.where((entry) =>
          entry['isDirectory']==true &&
          entry['isInaccessible']!=true &&
          entry['isInaccessibleSummary']!=true &&
          entry['path'] is String &&
          ((entry['pdfCount'] as num?)?.toInt() ?? 0)>0
        ).toList(growable:false);
      });
      if(openBrowser) await _showRecursiveStoragePdfs('Phone Storage',entries);
      if(inaccessibleRoots>0 && mounted) _message('$inaccessibleRoots granted location(s) could not be read; they were not marked empty.');
    } catch(error) {
      if(mounted)_message('Phone Storage scan failed; inaccessible locations were not marked empty: $error');
    }
  }

  Future<void> _showRecursiveStoragePdfs(String rootName, List<Map<String, Object?>> entries, {String initialPath = ''}) async {
    if (!mounted) return;
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => PhoneStorageBrowserScreen(
        rootName: rootName, entries: entries, onOpenPdf: _openExternalStoragePdf,
        initialPath: initialPath,
      ),
    ));
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move selected PDFs to Recycle Bin?'),
        content: Text('${selected.length} PDFs will be hidden. Files will not be erased.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Move')),
        ],
      ),
    );
    if (confirmed != true) return;
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
      await _patchDocument(document.id);
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
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

  Future<void> _moveToFolder(DocumentRecord document) async {
    final folders = await _folderRepository.allFoldersWithPaths();
    if (!mounted) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Move PDF to folder'),
              subtitle: Text('The PDF stays in the same local library.'),
            ),
            ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('Root / No folder'),
              trailing: document.folderId == null ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(sheetContext, ''),
            ),
            for (final option in folders)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(option.path),
                trailing: document.folderId == option.folder.id
                    ? const Icon(Icons.check, color: Colors.green)
                    : null,
                onTap: () => Navigator.pop(sheetContext, option.folder.id),
              ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    await _repository.moveToFolder(document, selected.isEmpty ? null : selected);
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
    return PopScope<void>(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _selectionMode && mounted) {
          _clearSelection();
        }
      },
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
        if (!widget.favoritesOnly && !widget.recentOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: _storageSummaryCard(
                    icon: Icons.phone_android,
                    title: 'Internal Storage',
                    value: _phonePdfCount == null ? 'Permission needed' : '$_phonePdfCount PDFs',
                    detail: _phoneStorageBytes == null ? 'Accessible locations not yet available' : '${_size(_phoneStorageBytes!)} used by PDFs',
                    onTap: _browsePhoneStorage,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _storageSummaryCard(
                    icon: Icons.folder_copy_outlined,
                    title: 'Grid Storage',
                    value: '$_totalDocumentCount PDFs',
                    detail: '${_size(_totalStorageBytes)} used · $_starredCount starred',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const FoldersScreen()),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (!widget.favoritesOnly && !widget.recentOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _storageSummaryCard(
              icon: Icons.delete_outline,
              title: 'Recycle Bin',
              value: '$_trashCount PDFs',
              detail: '${_size(_trashBytes)} · Restore or permanently delete',
              onTap: _showTrash,
            ),
          ),
        if (!widget.favoritesOnly && !widget.recentOnly && _phoneFolders.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Card(
              child: ExpansionTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: Text('Phone folders containing PDFs (${_phoneFolders.length})'),
                subtitle: const Text('Only folders with one or more PDFs'),
                children: [
                  SizedBox(
                    height: 260,
                    child: ListView.builder(
                      itemCount: _phoneFolders.length,
                      itemBuilder: (context, index) {
                        final folder = _phoneFolders[index];
                        final path = folder['path'] as String;
                        final count = (folder['pdfCount'] as num?)?.toInt() ?? 0;
                        final bytes = (folder['sizeBytes'] as num?)?.toInt() ?? 0;
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('$count PDFs · ${_size(bytes)}'),
                          onTap: () => _showRecursiveStoragePdfs(
                            'Phone Storage', _phoneEntries, initialPath: path,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
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
                PopupMenuButton<String>(
                  tooltip: 'More document actions',
                  icon: const Icon(Icons.more_vert),
                  onSelected: (action) {
                    if (action == 'trash') _showTrash();
                    if (action == 'select') setState(() { _selectionMode = true; _selectedIds.clear(); });
                    if (action == 'duplicates') {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const DocumentToolsScreen(section: 'tools', quickAction: 'duplicates'),
                        ),
                      );
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'trash',
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.delete_outline),
                        title: Text('Recycle Bin'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'duplicates',
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.copy_all_outlined),
                        title: Text('Check Duplicate File'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'select',
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.checklist),
                        title: Text('Select PDFs'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        if (_importing) const LinearProgressIndicator(),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.cloud_off_outlined, size: 42),
                            const SizedBox(height: 12),
                            const Text(
                              'Could not load documents',
                              style: TextStyle(fontWeight: FontWeight.w600),
                              textAlign: TextAlign.center,
                            ),
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
                    )
                  : _documents.isEmpty
                      ? _emptyState()
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            controller: _scrollController,
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
                        ),
        ),
      ],
    ),
    );
  }

  Widget _storageSummaryCard({
    required IconData icon,
    required String title,
    required String value,
    required String detail,
    required VoidCallback onTap,
  }) => Card(
    elevation: 0,
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 3),
            Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    ),
  );

  Widget _dashboardMetric(IconData icon, String value, String label) => Row(
    children: [
      Icon(icon, color: Colors.white, size: 20),
      const SizedBox(width: 6),
      Flexible(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white70, fontSize: 10)),
      ])),
    ],
  );

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
            : const CircleAvatar(child: Icon(Icons.picture_as_pdf_outlined)),
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
                    );
                  }
                }
                _starredCount = (_starredCount + (nextFavorite ? 1 : -1)).clamp(0, _totalDocumentCount).toInt();
              });
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
            PopupMenuItem(value: 'favorite',
              child: Text(document.isFavorite ? 'Remove from Star' : 'Add to Star')),
            const PopupMenuItem(value: 'category', child: Text('Set category')),
            const PopupMenuItem(value: 'move', child: Text('Move to folder')),
            const PopupMenuItem(value: 'tags', child: Text('Edit tags')),
            const PopupMenuItem(value: 'rename', child: Text('Rename')),
            const PopupMenuItem(value: 'share', child: Text('Share PDF')),
            const PopupMenuItem(value: 'reminder', child: Text('Add to reminder')), 
            const PopupMenuItem(value: 'relink', child: Text('Relink / Replace PDF')),
            const PopupMenuItem(value: 'trash', child: Text('Move to Recycle Bin')),
          ],
        ),
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
