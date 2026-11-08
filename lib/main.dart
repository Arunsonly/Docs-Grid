import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'features/documents/presentation/documents_screen.dart';
import 'features/documents/data/document_repository.dart';
import 'features/categories/presentation/categories_screen.dart';
import 'features/history/presentation/history_screen.dart';
import 'features/reminders/presentation/reminders_screen.dart';
import 'features/reminders/data/reminder_repository.dart';
import 'features/folders/presentation/folders_screen.dart';
import 'features/folders/data/folder_repository.dart';
import 'core/storage/storage_location_service.dart';
import 'features/tools/document_tools_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DocsGridApp());
}

class DocsGridApp extends StatefulWidget {
  const DocsGridApp({super.key});

  @override
  State<DocsGridApp> createState() => _DocsGridAppState();
}

class _DocsGridAppState extends State<DocsGridApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _themeMode = prefs.getBool('dark_mode') == true
        ? ThemeMode.dark
        : ThemeMode.light);
  }

  Future<void> _setDarkMode(bool enabled) async {
    setState(() => _themeMode = enabled ? ThemeMode.dark : ThemeMode.light);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dark_mode', enabled);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF2457C5));
    return MaterialApp(
      title: 'DocsGrid',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF6F7FB),
        cardTheme: const CardThemeData(color: Colors.white),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8EA9FF),
          brightness: Brightness.dark,
        ),
      ),
      home: DocsGridHome(
        darkMode: _themeMode == ThemeMode.dark,
        onDarkModeChanged: _setDarkMode,
      ),
    );
  }
}

class DocsGridHome extends StatefulWidget {
  const DocsGridHome({super.key, required this.darkMode, required this.onDarkModeChanged});
  final bool darkMode;
  final ValueChanged<bool> onDarkModeChanged;

  @override
  State<DocsGridHome> createState() => _DocsGridHomeState();
}

class _DocsGridHomeState extends State<DocsGridHome> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  bool _checkingIncomingShare = false;
  bool _reconcilingReminders = false;
  static const MethodChannel _storageChannel = MethodChannel('docsgrid/storage');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumeSharedPdfs();
      _reconcileReminders();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _consumeSharedPdfs();
      _reconcileReminders();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _reconcileReminders() async {
    if (_reconcilingReminders) return;
    _reconcilingReminders = true;
    try {
      await ReminderRepository().reconcileNotifications();
    } catch (_) {
      // Startup must remain usable when notification permission or the OS
      // scheduler is unavailable. Reconciliation is retried on next resume.
    } finally {
      _reconcilingReminders = false;
    }
  }

  Future<void> _consumeSharedPdfs() async {
    if (_checkingIncomingShare || !mounted) return;
    _checkingIncomingShare = true;
    try {
      final incoming = await _storageChannel.invokeMethod<List<dynamic>>('consumeSharedPdfs') ?? [];
      for (final item in incoming) {
        if (!mounted || item is! Map) continue;
        final path = item['path']?.toString();
        final originalName = item['name']?.toString() ?? 'Shared document.pdf';
        if (path == null) continue;
        final file = File(path);
        if (!await file.exists()) continue;
        try {
          final folders = await FolderRepository().allFoldersWithPaths();
          if (!mounted) return;
          String? selectedFolderId;
          final initialName = originalName.toLowerCase().endsWith('.pdf')
              ? originalName.substring(0, originalName.length - 4)
              : originalName;
          final nameController = TextEditingController(text: initialName);
          final config = await showDialog<Map<String, Object?>>(
            context: context,
            builder: (dialogContext) => StatefulBuilder(
              builder: (dialogContext, refresh) => AlertDialog(
                title: const Text('Save to DocsGrid'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(controller: nameController, decoration: const InputDecoration(labelText: 'File name', suffixText: '.pdf')),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: selectedFolderId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Choose folder'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('My Documents (root)')),
                      for (final option in folders)
                        DropdownMenuItem<String?>(value: option.folder.id, child: Text(option.path, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (value) => refresh(() => selectedFolderId = value),
                  ),
                  Align(alignment: Alignment.centerRight, child: TextButton.icon(
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('New folder'),
                    onPressed: () async {
                      final controller = TextEditingController();
                      final newName = await showDialog<String>(context: dialogContext, builder: (ctx) => AlertDialog(
                        title: const Text('Create folder'),
                        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(labelText: 'Folder name')),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Create')),
                        ],
                      ));
                      await WidgetsBinding.instance.endOfFrame;
                      controller.dispose();
                      if (newName == null || newName.trim().isEmpty || !dialogContext.mounted) return;
                      final created = await FolderRepository().create(name: newName, parentId: selectedFolderId);
                      final refreshed = await FolderRepository().allFoldersWithPaths();
                      refresh(() {
                        selectedFolderId = created.id;
                        folders
                          ..clear()
                          ..addAll(refreshed);
                      });
                    },
                  )),
                ]),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
                  FilledButton(onPressed: () => Navigator.pop(dialogContext, {
                    'name': nameController.text.trim(),
                    'folderId': selectedFolderId,
                  }), child: const Text('Save PDF')),
                ],
              ),
            ),
          );
          await WidgetsBinding.instance.endOfFrame;
          nameController.dispose();
          if (!mounted || config == null) continue;
          final chosenName = (config['name'] as String?)?.trim();
          final result = await DocumentRepository().importScannedPdf(
            file,
            displayName: chosenName == null || chosenName.isEmpty ? originalName : chosenName,
            targetFolderId: config['folderId'] as String?,
            sourceType: 'share',
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
              result.added == 1 ? 'Saved in DocsGrid.' : 'This PDF already exists in your library.',
            )));
          }
        } finally {
          // Shared attachments are staged in cache by the Android host.
          // Always remove them, including cancellation and failed imports.
          try {
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }
      }
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not import shared PDF: $error')));
    } finally {
      _checkingIncomingShare = false;
    }
  }

  Future<void> _showQuickActions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Quick actions'), subtitle: Text('Scan, create PDFs, search document text and set reminders.')),
          ListTile(leading: const Icon(Icons.document_scanner_outlined), title: const Text('Scan using camera'), onTap: () => Navigator.pop(sheetContext, 'camera')),
          ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Create PDF from gallery'), onTap: () => Navigator.pop(sheetContext, 'gallery')),
          ListTile(leading: const Icon(Icons.manage_search_outlined), title: const Text('On-device text indexing & search'), onTap: () => Navigator.pop(sheetContext, 'tools')),
          ListTile(leading: const Icon(Icons.notifications_active_outlined), title: const Text('Set a reminder'), onTap: () => Navigator.pop(sheetContext, 'reminder')),
        ]),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'reminder') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RemindersScreen()));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
      appBar: AppBar(title: const Text('Document tools')),
      body: DocumentToolsScreen(quickAction: action),
    )));
  }

  static const _titles = ['My Documents', 'Folders', 'Saved', 'Settings'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('DocsGrid · ${_titles[_selectedIndex]}',
            style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: switch (_selectedIndex) {
          0 => const DocumentsScreen(),
          1 => const FoldersScreen(),
          2 => const DocumentsScreen(favoritesOnly: true),
          _ => _SettingsScreen(darkMode: widget.darkMode, onDarkModeChanged: widget.onDarkModeChanged),
        },
      ),
      floatingActionButton: _selectedIndex == 0
          ? FloatingActionButton.small(
              tooltip: 'Quick document actions',
              onPressed: _showQuickActions,
              child: const Icon(Icons.document_scanner_outlined),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) => setState(() => _selectedIndex = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.description_outlined), label: 'Files'),
          NavigationDestination(icon: Icon(Icons.folder_outlined), label: 'Folders'),
          NavigationDestination(icon: Icon(Icons.star_border), label: 'Star'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
        ],
      ),
    );
  }
}

class _SettingsScreen extends StatefulWidget {
  const _SettingsScreen({required this.darkMode, required this.onDarkModeChanged});
  final bool darkMode;
  final ValueChanged<bool> onDarkModeChanged;

  @override
  State<_SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<_SettingsScreen> {
  Map<String, String>? _storageStatus;
  bool _checkingStorage = false;

  @override
  void initState() {
    super.initState();
    _refreshStorageStatus();
  }

  Future<void> _refreshStorageStatus() async {
    setState(() => _checkingStorage = true);
    try {
      final status = await StorageLocationService.instance.checkStorageAccess();
      if (mounted) setState(() => _storageStatus = status);
    } catch (error) {
      if (mounted) {
        setState(() => _storageStatus = {
          'status': 'unknown',
          'message': 'Could not check storage access: $error',
        });
      }
    } finally {
      if (mounted) setState(() => _checkingStorage = false);
    }
  }

  Future<void> _chooseStorage(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final folder = await StorageLocationService.instance.chooseFolder();
      if (folder == null || !context.mounted) return;
      final migrate = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Move existing PDF library?'),
          content: Text(
            'Use “${folder['name']}” for new imports and move your existing PDFs and folder structure there? '
            'Every PDF is verified before its old copy is removed.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('New imports only'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Move existing library'),
            ),
          ],
        ),
      );
      if (!context.mounted) return;
      await _refreshStorageStatus();
      if (!context.mounted) return;
      if (migrate != true) {
        messenger.showSnackBar(
          SnackBar(content: Text('Storage folder selected: ${folder['name']}. Existing PDFs were not moved.')),
        );
        return;
      }

      var completed = 0;
      var total = 0;
      var current = 'Preparing migration…';
      StateSetter? updateProgress;
      final progressDialog = showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            updateProgress = setDialogState;
            final value = total == 0 ? null : completed / total;
            return AlertDialog(
              title: const Text('Migrating PDF library'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: value),
                  const SizedBox(height: 14),
                  Text(total == 0 ? 'Scanning documents…' : '$completed of $total PDFs processed'),
                  const SizedBox(height: 6),
                  Text(current, maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: Theme.of(dialogContext).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  const Text('Keep DocsGrid open. Original files are removed only after verification and database update.'),
                ],
              ),
            );
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);
      try {
        final count = await DocumentRepository().migrateExistingLibraryToSelectedStorage(
          onProgress: (done, all, name) {
            completed = done;
            total = all;
            current = name;
            updateProgress?.call(() {});
          },
        );
        if (context.mounted) {
          Navigator.of(context, rootNavigator: true).pop();
          await progressDialog;
          messenger.showSnackBar(
            SnackBar(content: Text('Migration completed: $count PDFs moved and verified.')),
          );
        }
      } catch (error) {
        if (context.mounted) {
          Navigator.of(context, rootNavigator: true).pop();
          await progressDialog;
          messenger.showSnackBar(
            SnackBar(content: Text('Migration stopped safely: $error')),
          );
        }
      }
    } catch (error) {
      if (context.mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Storage operation stopped safely: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _storageStatus?['status'];
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.dark_mode_outlined),
          title: const Text('Dark appearance'),
          value: widget.darkMode,
          onChanged: widget.onDarkModeChanged,
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.health_and_safety_outlined),
          title: const Text('Storage access health'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (_checkingStorage) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            if (!_checkingStorage) Text(status == 'available' ? 'OK' : status == 'revoked' ? 'Repair' : 'Check',
              style: TextStyle(color: status == 'available' ? Colors.green : null)),
            IconButton(tooltip: 'Refresh', onPressed: _checkingStorage ? null : _refreshStorageStatus,
              icon: const Icon(Icons.refresh)),
          ]),
          onTap: _refreshStorageStatus,
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.sd_storage_outlined),
          title: const Text('Choose storage location'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _chooseStorage(context),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.backup_outlined),
          title: const Text('Backup'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('Backup')),
            body: const DocumentToolsScreen(section: 'backup', quickAction: 'backup'),
          ))),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.settings_backup_restore_outlined),
          title: const Text('Backup restore'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('Backup restore')),
            body: const DocumentToolsScreen(section: 'restore'),
          ))),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.build_outlined),
          title: const Text('Document tools'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('Document tools')),
            body: const DocumentToolsScreen(section: 'tools'),
          ))),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.access_time),
          title: const Text('Recently opened'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('Recently opened')),
            body: const DocumentsScreen(recentOnly: true),
          ))),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('Activity'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HistoryScreen())),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.notifications_active_outlined),
          title: const Text('Reminder'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RemindersScreen())),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.sell_outlined),
          title: const Text('Category & Tag'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('Category & Tag')),
            body: const CategoriesScreen(),
          ))),
        ),
        const Divider(height: 1),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('About'),
        ),
      ],
    );
  }
}
