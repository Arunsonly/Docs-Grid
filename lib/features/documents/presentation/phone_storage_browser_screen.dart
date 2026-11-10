import 'package:flutter/material.dart';

class PhoneStorageBrowserScreen extends StatefulWidget {
  const PhoneStorageBrowserScreen({
    super.key,
    required this.rootName,
    required this.entries,
    required this.onOpenPdf,
  });

  final String rootName;
  final List<Map<String, Object?>> entries;
  final Future<void> Function(String uri, String name) onOpenPdf;

  @override
  State<PhoneStorageBrowserScreen> createState() =>
      _PhoneStorageBrowserScreenState();
}

class _PhoneStorageBrowserScreenState
    extends State<PhoneStorageBrowserScreen> {
  String _currentPath = '';

  late final Set<String> _folderPaths = widget.entries
      .where((entry) => entry['isDirectory'] == true &&
          entry['isInaccessible'] != true &&
          entry['isInaccessibleSummary'] != true &&
          entry['path'] is String)
      .map((entry) => entry['path'] as String)
      .toSet();

  late final List<Map<String, Object?>> _inaccessible = widget.entries
      .where((entry) => entry['isInaccessible'] == true ||
          entry['isInaccessibleSummary'] == true)
      .toList(growable: false);

  late final List<Map<String, Object?>> _pdfs = widget.entries
      .where((entry) => entry['isDirectory'] != true)
      .toList(growable: false);

  List<String> get _crumbs =>
      _currentPath.isEmpty ? const [] : _currentPath.split('/');

  List<String> get _folders => (_folderPaths.where((path) {
        final parent =
            path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
        return parent == _currentPath;
      }).toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())));

  List<Map<String, Object?>> get _files => _pdfs
      .where((entry) => entry['folderPath'] == _currentPath)
      .toList(growable: false);

  int _countPdfsUnder(String folderPath) {
    final descendantPrefix = '$folderPath/';
    return _pdfs.where((entry) {
      final path = entry['folderPath'] as String? ?? '';
      return path == folderPath || path.startsWith(descendantPrefix);
    }).length;
  }

  int _sizeUnder(String folderPath) {
    final prefix = '$folderPath/';
    return _pdfs.where((entry) {
      final path = entry['folderPath'] as String? ?? '';
      return path == folderPath || path.startsWith(prefix);
    }).fold<int>(0, (sum, entry) =>
        sum + ((entry['sizeBytes'] as num?)?.toInt() ?? 0));
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  void _navigateBack() {
    if (_currentPath.isEmpty) return;
    final separator = _currentPath.lastIndexOf('/');
    setState(() {
      _currentPath =
          separator < 0 ? '' : _currentPath.substring(0, separator);
    });
  }

  @override
  Widget build(BuildContext context) {
    final folders = _folders;
    final files = _files;

    return PopScope<Object?>(
      canPop: _currentPath.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _currentPath.isNotEmpty) {
          _navigateBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.rootName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: 'Go to root',
              onPressed: _currentPath.isEmpty
                  ? null
                  : () => setState(() => _currentPath = ''),
              icon: const Icon(Icons.home_outlined),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_inaccessible.isNotEmpty)
              Material(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    const Icon(Icons.lock_outline),
                    const SizedBox(width: 8),
                    Expanded(child: Text(
                      '${_inaccessible.length} storage location(s) are inaccessible. They are not treated as empty.',
                    )),
                  ]),
                ),
              ),
            if (_currentPath.isNotEmpty)
              SizedBox(
                height: 54,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  children: [
                    TextButton(
                      onPressed: () => setState(() => _currentPath = ''),
                      child: Text(widget.rootName),
                    ),
                    for (var i = 0; i < _crumbs.length; i++) ...[
                      const Icon(Icons.chevron_right, size: 18),
                      TextButton(
                        onPressed: () => setState(
                          () => _currentPath = _crumbs.take(i + 1).join('/'),
                        ),
                        child: Text(_crumbs[i]),
                      ),
                    ],
                  ],
                ),
              ),
            Expanded(
              child: folders.isEmpty && files.isEmpty
                  ? const Center(child: Text('No PDFs in this folder.'))
                  : ListView(
                      children: [
                        for (final path in folders)
                          ListTile(
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(
                              path.split('/').last,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${_countPdfsUnder(path)} PDFs · ${_formatSize(_sizeUnder(path))}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () =>
                                setState(() => _currentPath = path),
                          ),
                        if (folders.isNotEmpty && files.isNotEmpty)
                          const Divider(height: 1),
                        for (final entry in files)
                          ListTile(
                            leading:
                                const Icon(Icons.picture_as_pdf_outlined),
                            title: Text(
                              entry['name'] as String,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: const Text('PDF document'),
                            onTap: () => widget.onOpenPdf(
                              entry['uri'] as String,
                              entry['name'] as String,
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
