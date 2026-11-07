import 'package:flutter/material.dart';

import 'features/documents/presentation/documents_screen.dart';
import 'features/categories/presentation/categories_screen.dart';
import 'features/history/presentation/history_screen.dart';
import 'features/folders/presentation/folders_screen.dart';

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

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const ListTile(
          leading: Icon(Icons.phonelink_lock_outlined),
          title: Text('Offline storage'),
          subtitle: Text('Current location: app-private storage. User-selectable Files folder is not ready yet.'),
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
            'Storage location selection, backup and restore, reminders and other settings are not implemented yet.',
            style: TextStyle(color: Colors.black54),
          ),
        ),
      ],
    );
  }
}
