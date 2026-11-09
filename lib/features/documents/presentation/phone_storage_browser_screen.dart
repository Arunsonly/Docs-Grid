import 'package:flutter/material.dart';

class PhoneStorageBrowserScreen extends StatefulWidget {
  const PhoneStorageBrowserScreen({super.key, required this.rootName, required this.entries, required this.onOpenPdf});
  final String rootName;
  final List<Map<String, Object?>> entries;
  final Future<void> Function(String uri, String name) onOpenPdf;

  @override
  State<PhoneStorageBrowserScreen> createState() => _PhoneStorageBrowserScreenState();
}

class _PhoneStorageBrowserScreenState extends State<PhoneStorageBrowserScreen> {
  String _currentPath = '';
  late final Set<String> _folderPaths = widget.entries.where((e) => e['isDirectory'] == true).map((e) => e['path'] as String).toSet();
  late final List<Map<String, Object?>> _pdfs = widget.entries.where((e) => e['isDirectory'] != true).toList(growable: false);
  List<String> get _crumbs => _currentPath.isEmpty ? const [] : _currentPath.split('/');
  List<String> get _folders => (_folderPaths.where((path) {
    final parent = path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
    return parent == _currentPath;
  }).toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())));
  List<Map<String, Object?>> get _files => _pdfs.where((e) => e['folderPath'] == _currentPath).toList(growable: false);
  @override
  Widget build(BuildContext context) {
    final folders = _folders;
    final files = _files;
    return Scaffold(
      appBar: AppBar(title: Text(widget.rootName, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [IconButton(tooltip: 'Go to root', onPressed: _currentPath.isEmpty ? null : () => setState(() => _currentPath = ''), icon: const Icon(Icons.home_outlined))]),
      body: Column(children: [
        if (_currentPath.isNotEmpty) SizedBox(height: 54, child: ListView(
          scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          children: [
            TextButton(onPressed: () => setState(() => _currentPath = ''), child: Text(widget.rootName)),
            for (var i = 0; i < _crumbs.length; i++) ...[
              const Icon(Icons.chevron_right, size: 18),
              TextButton(onPressed: () => setState(() => _currentPath = _crumbs.take(i + 1).join('/')), child: Text(_crumbs[i])),
            ],
          ],
        )),
        Expanded(child: folders.isEmpty && files.isEmpty
          ? const Center(child: Text('No PDFs in this folder.'))
          : ListView(children: [
            for (final path in folders) ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(path.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('\${_count(path)} PDFs'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => setState(() => _currentPath = path),
            ),
            if (folders.isNotEmpty && files.isNotEmpty) const Divider(height: 1),
            for (final entry in files) ListTile(
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: Text(entry['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: const Text('PDF document'),
              onTap: () => widget.onOpenPdf(entry['uri'] as String, entry['name'] as String),
            ),
          ])),
      ]),
    );
  }
}
