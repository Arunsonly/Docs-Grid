import 'package:flutter/material.dart';

void main() {
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

  static const _titles = ['My Documents', 'Folders', 'Favourites', 'Settings'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DocsGrid', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            tooltip: 'Search documents',
            onPressed: () => _showMessage('Document search will be added next.'),
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      body: SafeArea(
        child: _selectedIndex == 0
            ? _dashboard()
            : _placeholder(_titles[_selectedIndex]),
      ),
      floatingActionButton: _selectedIndex == 0
          ? FloatingActionButton.extended(
              onPressed: () => _showMessage('PDF import will be added next.'),
              icon: const Icon(Icons.add),
              label: const Text('Add PDFs'),
            )
          : null,
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

  Widget _dashboard() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      children: [
        Text('Your documents, organised.',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text('Keep important PDFs together on this device.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.black54)),
        const SizedBox(height: 20),
        Row(
          children: const [
            Expanded(child: _SummaryCard(icon: Icons.picture_as_pdf_outlined, label: 'PDF files', value: '0')),
            SizedBox(width: 12),
            Expanded(child: _SummaryCard(icon: Icons.folder_outlined, label: 'Folders', value: '0')),
          ],
        ),
        const SizedBox(height: 24),
        Text('Quick access', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        _QuickTile(
          icon: Icons.file_upload_outlined,
          title: 'Import multiple PDFs',
          subtitle: 'Choose files from your phone',
          onTap: () => _showMessage('PDF import will be added next.'),
        ),
        _QuickTile(
          icon: Icons.manage_search,
          title: 'Find a document',
          subtitle: 'Search by file name or document text',
          onTap: () => _showMessage('Search will be added after local PDF indexing.'),
        ),
        _QuickTile(
          icon: Icons.backup_outlined,
          title: 'Backup & restore',
          subtitle: 'Move your library to another phone',
          onTap: () => _showMessage('Offline backup and restore will be added in a later step.'),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.phonelink_lock_outlined),
              SizedBox(width: 10),
              Expanded(
                child: Text('Privacy first: DocsGrid is being designed to keep your documents on your device.'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _placeholder(String title) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.construction_outlined, size: 44),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text('This section will be built in the next development steps.',
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 12),
            Text(value, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
            Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

class _QuickTile extends StatelessWidget {
  const _QuickTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(child: Icon(icon)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
