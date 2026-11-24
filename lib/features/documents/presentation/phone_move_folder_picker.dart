import 'package:flutter/material.dart';

import '../../../core/storage/storage_location_service.dart';
import '../../../core/storage/grid_storage_boundary.dart';

class PhoneFolderDestination {
  const PhoneFolderDestination({required this.uri, required this.path});
  final String uri;
  final String path;
}

/// Existing Phone/SD/SAF destinations only; never changes DocsGrid's selected
/// library root. Lists one folder level at a time, not the complete phone tree.
class PhoneMoveFolderPicker extends StatefulWidget {
  const PhoneMoveFolderPicker({
    super.key,
    required this.roots,
    required this.listDirectory,
    required this.createDirectory,
    this.sourceFolderPath = '',
    this.excludedGrid,
  });

  final List<Map<String, String>> roots;
  final Future<List<Map<String, Object?>>> Function(String uri) listDirectory;
  final Future<String> Function(String parentUri, String name) createDirectory;
  final String sourceFolderPath;
  final GridStorageBoundary? excludedGrid;

  @override
  State<PhoneMoveFolderPicker> createState() => _PhoneMoveFolderPickerState();
}

class _PhoneMoveFolderPickerState extends State<PhoneMoveFolderPicker> {
  final List<PhoneFolderDestination> _ancestors = [];
  List<Map<String, Object?>> _folders = [];
  bool _loading = false;
  String? _error;
  int _request = 0;

  bool _safeFolderUri(String uri) =>
      uri.isNotEmpty &&
      !StorageLocationService.isRestrictedPhoneMoveDestination(uri) &&
      !(widget.excludedGrid?.isManagedPath(uri) ?? false);

  PhoneFolderDestination? get _selected =>
      _ancestors.isEmpty ? null : _ancestors.last;

  bool get _sameAsCurrentPhoneFolder {
    final selected = _selected;
    if (selected == null) return false;
    final destination = StorageLocationService.normalizePhoneFolderPath(selected.path)
        .toLowerCase();
    final source = StorageLocationService.normalizePhoneFolderPath(
      widget.sourceFolderPath).toLowerCase();
    return source.isNotEmpty && source == destination;
  }

  Future<void> _open(PhoneFolderDestination folder) async {
    if (!_safeFolderUri(folder.uri)) return;
    setState(() {
      _ancestors.add(folder);
      _loading = true;
      _error = null;
    });
    await _loadChildren(folder.uri);
  }

  Future<void> _loadChildren(String uri) async {
    final request = ++_request;
    try {
      final entries = await widget.listDirectory(uri);
      final folders = entries.where((entry) =>
          entry['isDirectory'] == true &&
          entry['isInaccessible'] != true &&
          entry['uri'] is String &&
          _safeFolderUri(entry['uri'] as String)).toList(growable: false)
        ..sort((a, b) => (a['name'] ?? '').toString().toLowerCase()
            .compareTo((b['name'] ?? '').toString().toLowerCase()));
      if (!mounted || request != _request) return;
      setState(() { _folders = folders; _loading = false; _error = null; });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _folders = [];
        _loading = false;
        _error = 'Folder is not accessible: $error';
      });
    }
  }

  Future<void> _back() async {
    if (_ancestors.isEmpty) return;
    ++_request;
    setState(() {
      _ancestors.removeLast();
      _folders = [];
      _error = null;
      _loading = _ancestors.isNotEmpty;
    });
    if (_ancestors.isNotEmpty) await _loadChildren(_ancestors.last.uri);
  }

  Future<void> _createFolder() async {
    final selected = _selected;
    if (selected == null || _loading || _error != null) return;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Phone folder'),
        content: TextField(
          key: const ValueKey('phone-move-new-folder-name'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Folder name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Create')),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || name == null || name.isEmpty) return;
    if (name == '.' || name == '..' || name.contains('/') ||
        name.contains('\\') || name.contains('\u0000')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid folder name.')),
      );
      return;
    }
    try {
      final newUri = await widget.createDirectory(selected.uri, name);
      if (!mounted) return;
      await _open(PhoneFolderDestination(
        uri: newUri,
        path: '${selected.path}/$name',
      ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not create folder: $error'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              if (selected != null)
                IconButton(key: const ValueKey('phone-move-back'),
                    tooltip: 'Parent folder',
                    onPressed: _back, icon: const Icon(Icons.arrow_back)),
              const Expanded(
                child: Text('Move to Phone folder',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
              ),
              IconButton(tooltip: 'Cancel',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close)),
            ]),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
              child: Text(selected?.path ?? 'Choose internal storage or an accessible location',
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium),
            ),
            const Divider(height: 1),
            Expanded(
              child: selected == null
                  ? ListView(
                      children: [
                        for (final root in widget.roots)
                          if (root['uri'] != null && _safeFolderUri(root['uri']!))
                            ListTile(
                              leading: const Icon(Icons.phone_android_outlined),
                              title: Text(root['name'] ?? 'Phone storage'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _open(PhoneFolderDestination(
                                uri: root['uri']!,
                                path: root['name'] ?? 'Phone storage',
                              )),
                            ),
                        if (widget.roots.isEmpty)
                          const ListTile(title: Text('No authorized Phone folders.')),
                      ],
                    )
                  : _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _error != null
                          ? Center(child: Text(_error!, textAlign: TextAlign.center))
                          : ListView(
                              children: [
                                if (_folders.isEmpty)
                                  const ListTile(title: Text('No subfolders here.')),
                                for (final folder in _folders)
                                  ListTile(
                                    leading: const Icon(Icons.folder_outlined),
                                    title: Text(folder['name'] as String? ?? 'Folder'),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: () => _open(PhoneFolderDestination(
                                      uri: folder['uri'] as String,
                                      path: '${selected.path}/${folder['name']}',
                                    )),
                                  ),
                              ],
                            ),
            ),
            if (selected != null) ...[
              const SizedBox(height: 8),
              Row(children: [
                TextButton.icon(
                  onPressed: _loading || _error != null ? null : _createFolder,
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('New folder'),
                ),
                const Spacer(),
                FilledButton.icon(
                  key: const ValueKey('phone-move-confirm'),
                  onPressed: _loading || _error != null || _sameAsCurrentPhoneFolder
                      ? null
                      : () => Navigator.pop(context, selected),
                  icon: const Icon(Icons.drive_file_move_outline),
                  label: const Text('Move here'),
                ),
              ]),
              if (_sameAsCurrentPhoneFolder)
                const Text('Choose a different folder from the current location.',
                  textAlign: TextAlign.end),
            ],
          ],
        ),
      ),
    );
  }
}
