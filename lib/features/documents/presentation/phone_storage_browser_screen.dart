import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/storage/phone_storage_scan_cache.dart';

class PhoneStorageBrowserScreen extends StatefulWidget {
  const PhoneStorageBrowserScreen({
    super.key,
    required this.rootName,
    required this.entries,
    this.pdfStream,
    this.onScanComplete,
    this.scanCache,
    this.embedded = false,
    this.onRequestPermission,
    this.onRefresh,
    required this.onOpenPdf,
    this.onMovePdf,
    this.onRenamePdf,
    this.onSharePdf,
    this.onTrashPdf,
    this.initialPath = '',
  });

  final String rootName;
  final List<Map<String, Object?>> entries;
  final Stream<Map<String, Object?>>? pdfStream;
  final PhoneStorageScanCache? scanCache;
  final bool embedded;
  final Future<void> Function()? onRequestPermission;
  final Future<void> Function()? onRefresh;
  final ValueChanged<List<Map<String, Object?>>>? onScanComplete;
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
  late final List<Map<String, Object?>> _streamedEntries;
  final List<Map<String, Object?>> _pendingStreamEntries = [];
  StreamSubscription<Map<String, Object?>>? _pdfSubscription;
  Timer? _streamFlushTimer;
  bool _isScanning = false;
  String? _scanError;

  List<Map<String, Object?>> get _entries => widget.scanCache?.entries ?? [
        ...widget.entries,
        ..._streamedEntries,
      ];
  bool get _scanning => widget.scanCache?.isScanning ?? _isScanning;

  @override
  void initState() {
    super.initState();
    _streamedEntries = <Map<String, Object?>>[];
    _isScanning = widget.pdfStream != null;
    final stream = widget.pdfStream;
    if (stream != null) {
      _pdfSubscription = stream.listen(
        (entry) {
          _pendingStreamEntries.add(entry);
          if (_pendingStreamEntries.length >= 8) {
            _flushStreamEntries();
          } else {
            _streamFlushTimer ??= Timer(
              const Duration(milliseconds: 100),
              _flushStreamEntries,
            );
          }
        },
        onError: (Object error) {
          _flushStreamEntries();
          if (!mounted) return;
          setState(() {
            _scanError = error.toString();
            _isScanning = false;
          });
          widget.onScanComplete?.call(_entries);
        },
        onDone: () {
          _flushStreamEntries();
          if (!mounted) return;
          setState(() => _isScanning = false);
          widget.onScanComplete?.call(_entries);
        },
        cancelOnError: false,
      );
    } else {
      widget.onScanComplete?.call(_entries);
    }
  }

  @override
  void dispose() {
    _streamFlushTimer?.cancel();
    _pdfSubscription?.cancel();
    super.dispose();
  }

  void _flushStreamEntries() {
    _streamFlushTimer?.cancel();
    _streamFlushTimer = null;
    if (_pendingStreamEntries.isEmpty) return;
    final batch = List<Map<String, Object?>>.from(_pendingStreamEntries);
    _pendingStreamEntries.clear();
    _streamedEntries.addAll(batch);
    if (mounted) setState(() {});
  }

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
      _entries.where(_isPdfFile).toList(growable: false);

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
    if (sourceChanged && mounted) {
      if (widget.embedded) {
        setState(() => _selectedFolderPath = null);
      } else {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cache = widget.scanCache;
    if (cache != null) {
      return AnimatedBuilder(
        animation: cache,
        builder: (context, _) => _buildBrowser(context),
      );
    }
    return _buildBrowser(context);
  }

  Widget _buildBrowser(BuildContext context) {
    final folders = _directPdfFolders;
    final selectedPath = _selectedFolderPath;
    final selectedFiles = selectedPath == null
        ? const <Map<String, Object?>>[]
        : folders[selectedPath] ?? const [];

    final browserBody = Column(
        children: [
          Expanded(
            child: selectedPath == null
          ? folders.isEmpty
              ? _scanning
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 12),
                          Text('Scanning… Finding PDF folders'),
                        ],
                      ),
                    )
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('No PDF folders found.'),
                            if (_scanError != null) ...[
                              const SizedBox(height: 8),
                              Text(_scanError!, textAlign: TextAlign.center),
                            ],
                          ],
                        ),
                      ),
                    )
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
              ? Center(
                  child: Text(
                    _isScanning ? 'Scanning…' : 'No PDF files in this folder.',
                  ),
                )
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
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                selectedPath == null
                    ? '${folders.length} folders${_scanning ? ' · Scanning…' : ''}'
                    : '${selectedFiles.length} PDFs${_scanning ? ' · Scanning…' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ],
      );
    if (widget.embedded) {
      return Column(
        children: [
          Row(children: [
            if (selectedPath != null)
              IconButton(
                tooltip: 'Back to folders',
                onPressed: () => setState(() => _selectedFolderPath = null),
                icon: const Icon(Icons.arrow_back),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Text(
                  selectedPath == null ? 'Phone PDF folders' : _folderName(selectedPath),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            if (widget.onRefresh != null)
              IconButton(
                tooltip: 'Refresh Phone storage',
                onPressed: () => widget.onRefresh!(),
                icon: const Icon(Icons.refresh),
              ),
          ]),
          Expanded(child: browserBody),
        ],
      );
    }
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
      body: browserBody,
    );
  }
}
