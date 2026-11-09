import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'features/documents/presentation/documents_screen.dart';
import 'features/documents/data/document_repository.dart';
import 'features/categories/presentation/categories_screen.dart';
import 'features/history/presentation/history_screen.dart';
import 'features/reminders/presentation/reminders_screen.dart';
import 'features/reminders/data/reminder_repository.dart';
import 'features/reminders/data/reminder_notifications.dart';
import 'features/folders/presentation/folders_screen.dart';
import 'features/folders/data/folder_repository.dart';
import 'core/storage/storage_location_service.dart';
import 'features/tools/document_tools_screen.dart' show DocumentToolsScreen;
import 'features/tools/document_scanner_screen.dart';

final GlobalKey<NavigatorState> docsGridNavigatorKey = GlobalKey<NavigatorState>();

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
      navigatorKey: docsGridNavigatorKey,
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
  static const MethodChannel _storageChannel = MethodChannel('docsgrid/storage');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ReminderNotifications.onDocumentNotificationTap = (documentId) {
      unawaited(_openReminderDocument(documentId));
    };
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _refreshReminderSchedules();
      final pendingDocumentId = ReminderNotifications.takePendingDocumentId();
      if (pendingDocumentId != null) await _openReminderDocument(pendingDocumentId);
      await _consumeSharedPdfs();
      await _offerRestoreOnFirstLaunch();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshReminderSchedules());
      unawaited(_consumeSharedPdfs());
    }
  }

  Future<void> _openReminderDocument(String documentId) async {
    try {
      final document = await DocumentRepository().getById(documentId);
      if (!mounted) {
        ReminderNotifications.queueDocumentTap(documentId);
        return;
      }
      if (document == null || document.storagePath.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('This reminder’s PDF is no longer in the library.')),
        );
        return;
      }
      await DocumentRepository().markOpened(document);
      final isProviderUri = document.storagePath.startsWith('content://') ||
          document.storagePath.startsWith('file://');
      if (isProviderUri) {
        await StorageLocationService.instance.openPdf(document.storagePath);
      } else {
        final file = File(document.storagePath);
        if (!await file.exists()) {
          throw StateError('The PDF file is missing from local storage.');
        }
        final result = await OpenFilex.open(document.storagePath);
        if (result.type != ResultType.done) {
          throw StateError(result.message.isEmpty ? 'No PDF viewer is available.' : result.message);
        }
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open reminder PDF: $error')),
        );
      }
    }
  }

  Future<void> _refreshReminderSchedules() async {
    try {
      await ReminderRepository().rescheduleEnabled();
    } catch (_) {
      // Document access remains available even if the OS notification queue
      // cannot be reconciled (for example, when notification permission is off).
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _offerRestoreOnFirstLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('docsgrid_restore_prompt_shown') == true) return;
    await prefs.setBool('docsgrid_restore_prompt_shown', true);
    if (!mounted) return;
    if (Platform.isAndroid) {
      try {
        if (await StorageLocationService.instance.hasAllFilesAccess()) {
          await StorageLocationService.instance.portableDataLocations();
        }
      } catch (_) {
        // Fresh setup remains available; recovery surfaces permission failures.
      }
    }

    final restoreChoice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Recover your DocsGrid data?'),
        content: const Text(
          'After reinstall, DocsGrid can look for portable backup ZIPs and existing PDFs '
          'in Android/media/com.docsgrid. A backup ZIP can recover documents, folders, '
          'categories, tags, reminders, history and settings. PDFs found without a backup '
          'can be imported, but their old categories and reminders cannot be reconstructed '
          'from PDF files alone. Nothing is restored or deleted without your confirmation.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'later'),
            child: const Text('Later'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'fresh'),
            child: const Text('Start fresh'),
          ),
          TextButton.icon(
            onPressed: () => Navigator.pop(ctx, 'pdfs'),
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('Recover existing PDFs'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, 'recover'),
            icon: const Icon(Icons.restore),
            label: const Text('Restore previous data'),
          ),
        ],
      ),
    );
    if (!mounted || (restoreChoice != 'recover' && restoreChoice != 'pdfs')) return;
    if (restoreChoice == 'pdfs') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Recover existing PDFs')),
        body: const DocumentToolsScreen(quickAction: 'recover_loose_pdfs'),
      )));
      return;
    }

    var hasPortableBackups = false;
    if (Platform.isAndroid) {
      try {
        if (await StorageLocationService.instance.hasAllFilesAccess()) {
          final locations = await StorageLocationService.instance.portableDataLocations();
          final backupUri = locations['backupsUri'];
          if (backupUri != null && backupUri.startsWith('file://')) {
            final directory = Directory(Uri.parse(backupUri).toFilePath());
            hasPortableBackups = await directory.exists() &&
                await directory.list(followLinks: false).any(
                  (item) => item is File && item.path.toLowerCase().endsWith('.zip'),
                );
          }
        }
      } catch (_) {
        // The recovery route will show the actionable permission/storage error.
      }
    }

    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
      appBar: AppBar(title: const Text('Recover DocsGrid')),
      body: DocumentToolsScreen(
        quickAction: hasPortableBackups ? 'restore_latest_backup' : 'restore_portable',
      ),
    )));
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
        if (!mounted) return;
        if (config == null) { await file.delete(); continue; }
        final chosenName = (config['name'] as String?)?.trim();
        final result = await DocumentRepository().importScannedPdf(
          file,
          displayName: chosenName == null || chosenName.isEmpty ? originalName : chosenName,
          targetFolderId: config['folderId'] as String?,
          sourceType: 'share',
        );
        await file.delete();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
            result.added == 1 ? 'Saved in DocsGrid.' : 'This PDF already exists in your library.',
          )));
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
          ListTile(leading: const Icon(Icons.manage_search_outlined), title: const Text('OCR Search Inside PDF'), onTap: () => Navigator.pop(sheetContext, 'tools')),
          ListTile(leading: const Icon(Icons.notifications_active_outlined), title: const Text('Set a reminder'), onTap: () => Navigator.pop(sheetContext, 'reminder')),
        ]),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'reminder') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RemindersScreen()));
      return;
    }
    final pageTitle = switch (action) {
      'camera' => 'Scan document',
      'gallery' => 'Create PDF from gallery',
      'tools' => 'OCR Search',
      _ => 'Document tools',
    };
    if (action == 'camera' || action == 'gallery') {
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DocumentScannerScreen(useCamera: action == 'camera'),
        fullscreenDialog: true,
      ));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
      appBar: AppBar(title: Text(pageTitle)),
      body: DocumentToolsScreen(quickAction: action),
    )));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DocsGrid', style: TextStyle(fontWeight: FontWeight.w700)),
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
        if (Platform.isAndroid)
          FutureBuilder<bool>(
            future: StorageLocationService.instance.hasAllFilesAccess(),
            builder: (context, snapshot) {
              final granted = snapshot.data == true;
              return ListTile(
                leading: Icon(
                  granted ? Icons.folder_special : Icons.folder_off_outlined,
                  color: granted ? Theme.of(context).colorScheme.primary : null,
                ),
                title: const Text('Full internal storage access'),
                subtitle: Text(granted
                    ? 'Allowed. DocsGrid can access shared internal storage.'
                    : 'Required for personal-use full storage browsing and automatic recovery discovery.'),
                trailing: granted
                    ? const Icon(Icons.check_circle_outline)
                    : const Icon(Icons.chevron_right),
                onTap: () async {
                  try {
                    await StorageLocationService.instance.requestAllFilesAccess();
                  } catch (error) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Could not open storage permission settings: $error')),
                      );
                    }
                  }
                },
              );
            },
          ),
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
          title: const Text('Backup & Restore'),
          subtitle: const Text('Create backup · Restore backup'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('Backup & Restore')),
            body: const DocumentToolsScreen(section: 'backup_restore'),
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
