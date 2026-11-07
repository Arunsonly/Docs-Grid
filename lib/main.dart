import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'features/documents/presentation/documents_screen.dart';
import 'features/documents/data/document_repository.dart';
import 'features/categories/presentation/categories_screen.dart';
import 'features/history/presentation/history_screen.dart';
import 'features/reminders/presentation/reminders_screen.dart';
import 'features/folders/presentation/folders_screen.dart';
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

class _DocsGridHomeState extends State<DocsGridHome> {
  int _selectedIndex = 0;

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
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) => setState(() => _selectedIndex = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.description_outlined), label: 'Files'),
          NavigationDestination(icon: Icon(Icons.folder_outlined), label: 'Folders'),
          NavigationDestination(icon: Icon(Icons.star_border), label: 'Saved'),
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
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.dark_mode_outlined),
          title: const Text('Dark appearance'),
          subtitle: const Text('Use a dark theme throughout DocsGrid.'),
          value: widget.darkMode,
          onChanged: widget.onDarkModeChanged,
        ),
        const Divider(),
        Card(
          child: ListTile(
            leading: Icon(_storageStatus?['status'] == 'available'
                ? Icons.cloud_done_outlined
                : _storageStatus?['status'] == 'revoked'
                    ? Icons.warning_amber_rounded
                    : Icons.storage_outlined),
            title: const Text('Storage access health'),
            subtitle: Text(_checkingStorage
                ? 'Checking saved folder permission…'
                : _storageStatus?['message'] ?? 'Storage status not checked yet.'),
            trailing: IconButton(
              tooltip: 'Check again',
              onPressed: _checkingStorage ? null : _refreshStorageStatus,
              icon: const Icon(Icons.refresh),
            ),
          ),
        ),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.phonelink_lock_outlined),
          title: Text(_storageStatus?['status'] == 'revoked'
              ? 'Repair storage permission'
              : 'Offline storage'),
          subtitle: Text(_storageStatus?['status'] == 'revoked'
              ? 'Select the same folder again to restore access. Existing PDF records will not be deleted.'
              : 'Choose a folder for PDFs and safely migrate your existing library.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _chooseStorage(context),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.history_toggle_off_outlined),
          title: const Text('Recently opened'),
          subtitle: const Text('Open documents you viewed most recently.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('Recently opened')),
                body: const DocumentsScreen(recentOnly: true),
              ),
            ),
          ),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.category_outlined),
          title: const Text('Categories & tags'),
          subtitle: const Text('Create and manage document categories and tags.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('Categories & tags')),
                body: const CategoriesScreen(),
              ),
            ),
          ),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.notifications_active_outlined),
          title: const Text('Reminders'),
          subtitle: const Text('Create and manage dates and times saved on this device.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const RemindersScreen()),
          ),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('Activity history'),
          subtitle: const Text('Review recent document actions stored on this device.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const HistoryScreen()),
          ),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.build_circle_outlined),
          title: const Text('Document tools'),
          subtitle: const Text('On-device OCR, scan to PDF, duplicate review and backup tools.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('Document tools')),
                body: const DocumentToolsScreen(),
              ),
            ),
          ),
        ),
        const Divider(),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('About DocsGrid'),
          subtitle: Text('Personal document organiser · Version 0.1.0'),
        ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'DocsGrid stores documents and reminders on this device. Reminders support one-time, daily and weekly schedules; backup and restore verify archive contents before restoring. Physical-device notification and storage-permission checks are still required.',
            style: TextStyle(color: Colors.black54),
          ),
        ),
      ],
    );
  }
}
