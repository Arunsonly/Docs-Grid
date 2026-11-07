import 'package:flutter/material.dart';

import 'features/documents/presentation/documents_screen.dart';
import 'features/documents/data/document_repository.dart';
import 'features/categories/presentation/categories_screen.dart';
import 'features/history/presentation/history_screen.dart';
import 'features/reminders/presentation/reminders_screen.dart';
import 'features/folders/presentation/folders_screen.dart';
import 'core/storage/storage_location_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DocsGridApp());
}

class DocsGridApp extends StatelessWidget {
  const DocsGridApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DocsGrid',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2457C5)),
        scaffoldBackgroundColor: const Color(0xFFF6F7FB),
        cardTheme: const CardThemeData(color: Colors.white),
      ),
      home: const DocsGridHome(),
    );
  }
}

class DocsGridHome extends StatefulWidget {
  const DocsGridHome({super.key});

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
          _ => const _SettingsScreen(),
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

class _SettingsScreen extends StatelessWidget {
  const _SettingsScreen();

  Future<void> _chooseStorage(BuildContext context) async {
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
      if (migrate != true) {
        ScaffoldMessenger.of(context).showSnackBar(
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Migration completed: $count PDFs moved and verified.')),
          );
        }
      } catch (error) {
        if (context.mounted) {
          Navigator.of(context, rootNavigator: true).pop();
          await progressDialog;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Migration stopped safely: $error')),
          );
        }
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
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
        ListTile(
          leading: const Icon(Icons.phonelink_lock_outlined),
          title: const Text('Offline storage'),
          subtitle: const Text('Choose a folder for PDFs and safely migrate your existing library.'),
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
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('About DocsGrid'),
          subtitle: Text('Personal document organiser · Version 0.1.0'),
        ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'User-selected storage, scheduled notifications, recurring reminders, backup and restore are still being developed.',
            style: TextStyle(color: Colors.black54),
          ),
        ),
      ],
    );
  }
}
