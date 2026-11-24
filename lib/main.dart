import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'features/documents/presentation/documents_screen.dart';
import 'features/documents/data/document_repository.dart';
import 'features/documents/presentation/smart_collections_screen.dart';
import 'features/categories/presentation/categories_screen.dart';
import 'features/history/presentation/history_screen.dart';
import 'features/reminders/presentation/reminders_screen.dart';
import 'features/reminders/presentation/reminder_inbox_sheet.dart';
import 'features/reminders/data/reminder_repository.dart';
import 'features/reminders/data/reminder_notifications.dart';
import 'features/folders/presentation/folders_screen.dart';
import 'features/folders/data/folder_repository.dart';
import 'core/storage/storage_location_service.dart';
import 'features/tools/document_tools_screen.dart' show DocumentToolsScreen;
import 'features/tools/document_tools_service.dart';
import 'core/database/app_database.dart';
import 'core/storage/portable_snapshot_events.dart';
import 'core/backup/backup_automation.dart';
import 'core/diagnostics/startup_timeline.dart';
import 'core/diagnostics/diagnostic_log_store.dart';

final GlobalKey<NavigatorState> docsGridNavigatorKey = GlobalKey<NavigatorState>();

void main() {
  StartupTimeline.mark('dart_main_enter');
  WidgetsFlutterBinding.ensureInitialized();
  // Capture unexpected framework and asynchronous failures in a bounded,
  // local diagnostic journal. Do not change Flutter's exception presentation.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    unawaited(DiagnosticLogStore.instance.recordError(
        'Flutter framework error', details.exception));
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    unawaited(DiagnosticLogStore.instance.recordError(
        'Unhandled asynchronous error', error));
    return false; // Preserve the platform's normal unhandled-error behavior.
  };
  StartupTimeline.mark('flutter_binding_ready');
  StartupTimeline.mark('run_app_called');
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
    StartupTimeline.mark('theme_read_start');
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _themeMode = prefs.getBool('dark_mode') == true
        ? ThemeMode.dark
        : ThemeMode.light);
    StartupTimeline.mark('theme_read_ready');
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

  /// Distinct element identities are REQUIRED because the Home and Phone
  /// tabs both use DocumentsScreen but initialize completely different data.
  /// Without distinct keys Flutter reuses the Phone State on Phone -> Home:
  /// its initState never calls _load(), leaving the Home summary at zero.
  /// Returning from a Phone/Grid root goes to Home, never exits the app.
  /// Nested folders still handle their own Back navigation first.
  static int destinationAfterStorageBack(int currentIndex) =>
      currentIndex == 0 || currentIndex == 2 ? 1 : currentIndex;

  static Widget screenForTab(int index) => switch (index) {
    0 => const DocumentsScreen(
      key: ValueKey('docsgrid-phone-tab'),
      phoneOnly: true,
    ),
    1 => const DocumentsScreen(
      key: ValueKey('docsgrid-home-tab'),
    ),
    _ => const FoldersScreen(),
  };
  final bool darkMode;
  final ValueChanged<bool> onDarkModeChanged;

  @override
  State<DocsGridHome> createState() => _DocsGridHomeState();
}

class _DocsGridHomeState extends State<DocsGridHome> with WidgetsBindingObserver {
  int _selectedIndex = 1;
  int _iosPhoneBrowseRevision = 0;
  int _dueReminderCount = 0;
  // Lazily mount each tab once. Preserve its scroll, folder and loaded data
  // while the user switches between Phone, Home and Grid.
  final Set<int> _visitedTabs = <int>{1};
  static const MethodChannel _appLifecycleChannel =
      MethodChannel('docsgrid/app_lifecycle');
  bool _checkingIncomingShare = false;
  static const MethodChannel _storageChannel = MethodChannel('docsgrid/storage');
  StreamSubscription<void>? _snapshotChangesSubscription;
  Timer? _snapshotDebounce;
  Timer? _snapshotPoll;
  Timer? _snapshotCleanupPoll;
  DateTime? _lastSnapshotCleanup;
  bool _snapshotWriteInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    StartupTimeline.mark('root_home_init');
    _snapshotChangesSubscription =
        PortableSnapshotEvents.changes.listen((_) => _schedulePortableSnapshot());
    // SQLite revision triggers are the durable source of truth. This low-cost
    // foreground poll also covers mutations performed by legacy/background code
    // that does not emit an in-process change signal.
    _snapshotPoll = Timer.periodic(
      const Duration(minutes: 15),
      (_) => _schedulePortableSnapshot(),
    );
    // Expired metadata snapshots also need cleanup when no files are edited.
    _snapshotCleanupPoll = Timer.periodic(
      const Duration(hours: 6),
      (_) => unawaited(_maintainPortableSnapshots()),
    );
    ReminderNotifications.onDocumentNotificationTap = (documentId) {
      unawaited(_openReminderDocument(documentId));
    };
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // No automatic migration on launch: moving legacy PDFs must require
      // an explicit action in Settings and must never delete an original.
      // Initialize best-effort Android background jobs without blocking first paint.
      unawaited(BackupAutomation.initializeAndroid());
      _schedulePortableSnapshot();
      unawaited(_refreshReminderSchedules());
      final pendingDocumentId = ReminderNotifications.takePendingDocumentId();
      if (pendingDocumentId != null) await _openReminderDocument(pendingDocumentId);
      // Keep incoming share and first-run recovery sequential: both may show
      // dialogs, so running them concurrently would lose or stack user prompts.
      await _consumeSharedPdfs();
      await _offerRestoreOnFirstLaunch();
      unawaited(BackupAutomation.runDueForegroundBackups());
      unawaited(_maintainPortableSnapshots());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshReminderSchedules());
      unawaited(_consumeSharedPdfs());
      _schedulePortableSnapshot();
      unawaited(BackupAutomation.runDueForegroundBackups());
      unawaited(_maintainPortableSnapshots());
    }
  }

  Future<void> _chooseIosPhoneFilesFolder() async {
    if (!Platform.isIOS) return;
    try {
      final chosen =
          await StorageLocationService.instance.choosePhoneFolder();
      if (chosen != null && mounted) {
        // Recreate only Phone's view so it reindexes the newly granted Files
        // location. Grid's selected storage and all PDF records stay intact.
        setState(() => ++_iosPhoneBrowseRevision);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not open Apple Files folder: $error'),
        ));
      }
    }
  }

  void _returnToHomeFromStorage() {
    final destination = DocsGridHome.destinationAfterStorageBack(_selectedIndex);
    if (destination != _selectedIndex && mounted) {
      setState(() => _selectedIndex = destination);
      unawaited(_refreshReminderBadge());
    }
  }

  Future<void> _refreshReminderBadge() async {
    try {
      final items = await ReminderRepository().list();
      final count = ReminderInboxSheet.dueCount(items, DateTime.now());
      if (mounted && count != _dueReminderCount) {
        setState(() => _dueReminderCount = count);
      }
    } catch (_) {
      // The badge is optional and must never block Home or PDF access.
    }
  }

  Future<void> _showReminderCenter() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => ReminderInboxSheet(
        reminders: ReminderRepository().list(),
        onOpenDocument: (documentId) =>
            unawaited(_openReminderDocument(documentId)),
        onOpenAll: () {
          if (!mounted) return;
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const RemindersScreen()))
              .then((_) => unawaited(_refreshReminderBadge()));
        },
      ),
    );
    unawaited(_refreshReminderBadge());
  }

  void _backgroundApp() {
    if (!Platform.isAndroid) return;
    // At a tab root, Back behaves like Home: background the Android task
    // instead of destroying the Flutter Activity and its in-memory indexes.
    unawaited(() async {
      try {
        final moved = await _appLifecycleChannel
            .invokeMethod<bool>('moveTaskToBack');
        if (moved != true) await SystemNavigator.pop();
      } catch (_) {
        // A missing native channel should still allow the user to exit.
        await SystemNavigator.pop();
      }
    }());
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
      await StorageLocationService.instance.openPdf(
        document.storagePath, gridPdf: true,
      );
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
    await _refreshReminderBadge();
  }

  Future<void> _maintainPortableSnapshots() async {
    final now = DateTime.now().toUtc();
    if (_lastSnapshotCleanup != null &&
        now.difference(_lastSnapshotCleanup!) < const Duration(hours: 6)) {
      return;
    }
    _lastSnapshotCleanup = now;
    try {
      await DocumentToolsService().cleanExpiredPortableSnapshots();
    } catch (_) {
      // Permission/provider failure must never block the PDF library.
      _lastSnapshotCleanup = null;
    }
  }

  void _schedulePortableSnapshot() {
    _snapshotDebounce?.cancel();
    _snapshotDebounce = Timer(const Duration(seconds: 2), () {
      unawaited(_writePortableSnapshotIfDirty());
    });
  }

  Future<void> _writePortableSnapshotIfDirty() async {
    if (!mounted || _snapshotWriteInFlight) return;
    _snapshotWriteInFlight = true;
    try {
      if (!await AppDatabase.instance.isPortableSnapshotDirty()) return;
      if (!await AppDatabase.instance.hasPortableUserData()) return;
      // Coalesce bursts of writes into one recovery point. Dirty state remains
      // set until the next eligible pass; the 15-minute poll is a fallback.
      final lastSnapshotAt =
          await AppDatabase.instance.portableSnapshotLastAt();
      if (lastSnapshotAt != null &&
          !lastSnapshotAt.isAfter(DateTime.now().toUtc()) &&
          DateTime.now().toUtc().difference(lastSnapshotAt) <
              const Duration(minutes: 5)) {
        return;
      }
      final locations = await StorageLocationService.instance
          .portableDataLocationsIfAvailable();
      if (locations['databaseUri'] == null) return;
      await DocumentToolsService().createPortableMetadataSnapshot();
      // A write which raced with the export leaves the revision dirty; queue
      // exactly one follow-up snapshot instead of declaring a stale export current.
      if (await AppDatabase.instance.isPortableSnapshotDirty()) {
        _schedulePortableSnapshot();
      }
    } catch (_) {
      // Keep the dirty revision. The next foreground poll/resume retries it.
    } finally {
      _snapshotWriteInFlight = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _snapshotChangesSubscription?.cancel();
    _snapshotDebounce?.cancel();
    _snapshotPoll?.cancel();
    _snapshotCleanupPoll?.cancel();
    super.dispose();
  }

  Future<void> _offerRestoreOnFirstLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('docsgrid_restore_prompt_shown') == true) return;
    final snoozedUntil = DateTime.tryParse(
      prefs.getString('docsgrid_restore_prompt_snoozed_until') ?? '',
    );
    if (snoozedUntil != null && snoozedUntil.isAfter(DateTime.now())) return;
    if (!mounted) return;
    if (Platform.isAndroid) {
      // A kept app-private SQLite database is already the live library.
      // Never offer an automatic restore over meaningful retained user data.
      // Manual recovery of other sources remains available through Settings.
      try {
        if (await AppDatabase.instance.hasPortableUserData()) {
          await prefs.setBool('docsgrid_restore_prompt_shown', true);
          await prefs.remove('docsgrid_restore_prompt_snoozed_until');
          return;
        }
      } catch (error) {
        // DB errors are NOT proof that old PDFs disappeared. Keep the existing
        // read-only recovery discovery flow available and log the failure.
        unawaited(DiagnosticLogStore.instance.recordError(
            'Existing database recovery check', error));
      }
      if (!mounted) return;
      final storage = StorageLocationService.instance;
      Map<String, String>? oldSource;
      bool storageInspected = false;
      try {
        storageInspected = await storage.hasAllFilesAccess();
        if (storageInspected) {
          oldSource = await storage.discoverOldDocsGridStorage();
        }
      } catch (error) {
        // Discovery is read-only and optional. A provider failure is NOT
        // evidence that the user's old files do not exist.
        unawaited(DiagnosticLogStore.instance.recordError(
            'First launch old storage discovery', error));
        storageInspected = false;
      }
      if (!mounted) return;

      // An empty folder made by this fresh install is not proof of old data.
      // Do not show a misleading "existing database" prompt.
      if (storageInspected && oldSource == null) {
        await prefs.setBool('docsgrid_restore_prompt_shown', true);
        return;
      }

      final found = oldSource != null;
      final descriptions = <String>[
        if (oldSource?['detectedSnapshot'] == 'true')
          'a saved metadata snapshot',
        if (oldSource?['detectedBackup'] == 'true')
          'a backup ZIP',
        if (oldSource?['detectedPdfs'] == 'true')
          'previous PDF files',
      ];
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(found
              ? 'Existing DocsGrid data found'
              : 'Check for previous DocsGrid data'),
          content: Text(found
              ? 'This phone has ${descriptions.join(', ')} in a DocsGrid storage folder. '
                'Would you like to restore it or start fresh? '
                'Starting fresh never deletes the old folder.'
              : 'DocsGrid cannot inspect existing storage until Android '
                'grants access. You may choose an old DocsGrid folder manually, '
                'or start fresh without deleting any old files.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'later'),
              child: const Text('Later'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'fresh'),
              child: const Text('Start fresh'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'restore'),
              child: const Text('Restore data'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (action == 'fresh') {
        await prefs.setBool('docsgrid_restore_prompt_shown', true);
        await prefs.remove('docsgrid_restore_prompt_snoozed_until');
        return;
      }
      if (action != 'restore') {
        await prefs.setString('docsgrid_restore_prompt_snoozed_until',
            DateTime.now().add(const Duration(days: 1)).toIso8601String());
        return;
      }

      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Select recovery source'),
          content: const Text(
            'Recovery reads from the old folder. DocsGrid keeps its active '
            'storage, PDFs and existing backup destination unchanged.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('Cancel'),
            ),
            if (oldSource != null)
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'old'),
                child: const Text('From old Storage location'),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'choose'),
              child: const Text('Choose another location'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      Map<String, String>? source;
      if (choice == 'old') {
        source = oldSource;
      } else if (choice == 'choose') {
        try {
          source = await storage.chooseRecoveryFolder();
        } catch (error) {
          unawaited(DiagnosticLogStore.instance.recordError(
              'Choose old storage source', error));
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text('Cannot open old folder: $error')));
          }
          return;
        }
      }
      if (source == null || !mounted) return;
      // Preserve an avenue to retry on the next launch if restore is cancelled
      // or the old snapshot turns out to be incomplete.
      await prefs.setString('docsgrid_restore_prompt_snoozed_until',
          DateTime.now().add(const Duration(days: 1)).toIso8601String());
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Restore previous DocsGrid data')),
          body: DocumentToolsScreen(
            quickAction: 'restore_selected_portable',
            initialRecoverySource: source,
            section: 'backup_restore',
          ),
        ),
      ));
      return;
    }

    if (!mounted) return;
    final restoreChoice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Recover your DocsGrid data?'),
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
    if (!mounted) return;
    if (restoreChoice == 'later' || restoreChoice == null) {
      await prefs.setString(
        'docsgrid_restore_prompt_snoozed_until',
        DateTime.now().add(Duration(days: restoreChoice == 'later' ? 7 : 1))
            .toIso8601String(),
      );
      return;
    }
    if (restoreChoice == 'fresh') {
      await prefs.setBool('docsgrid_restore_prompt_shown', true);
      await prefs.remove('docsgrid_restore_prompt_snoozed_until');
      return;
    }
    if (restoreChoice != 'recover' && restoreChoice != 'pdfs') return;
    if (restoreChoice == 'pdfs') {
      await prefs.setBool('docsgrid_restore_prompt_shown', true);
      await prefs.remove('docsgrid_restore_prompt_snoozed_until');
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Recover existing PDFs')),
        body: const DocumentToolsScreen(
          quickAction: 'recover_loose_pdfs',
          section: 'backup_restore',
        ),
      )));
      return;
    }

    var hasPortableBackups = false;
    if (Platform.isAndroid) {
      try {
        await StorageLocationService.instance.portableDataLocationsIfAvailable();
        hasPortableBackups =
            (await DocumentToolsService().listPortableBackupArchives()).isNotEmpty;
      } catch (_) {
        // Portable metadata snapshot recovery remains available when ZIP access is limited.
      }
    }

    if (!mounted) return;
    await prefs.setBool('docsgrid_restore_prompt_shown', true);
    await prefs.remove('docsgrid_restore_prompt_snoozed_until');
    final restoreAction =
        hasPortableBackups ? 'restore_latest_backup' : 'restore_portable';
    // The previous Offstage route hid both recovery progress and its outcome.
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Restore DocsGrid data')),
        body: DocumentToolsScreen(
          quickAction: restoreAction,
          section: 'backup_restore',
        ),
      ),
    ));
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
        if (config == null) {
          await _storageChannel.invokeMethod<bool>('finishSharedPdf', {
            'path': file.path, 'outcome': 'cancelled',
          });
          continue;
        }
        final chosenName = (config['name'] as String?)?.trim();
        final stageId = RegExp(r'^([0-9a-fA-F-]{36})_')
            .firstMatch(file.uri.pathSegments.last)?.group(1);
        final result = await DocumentRepository().importScannedPdf(
          file,
          displayName: chosenName == null || chosenName.isEmpty ? originalName : chosenName,
          targetFolderId: config['folderId'] as String?,
          sourceType: 'share',
          shareImportId: stageId,
        );
        await _storageChannel.invokeMethod<bool>('finishSharedPdf', {
          'path': file.path, 'outcome': 'committed',
        });
        // A successful save is immediately visible; preserve only duplicate
        // feedback because users must know why another PDF was not added.
        if (mounted && result.added != 1) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('This PDF already exists in your library.')),
          );
        }
      }
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not import shared PDF: $error')));
    } finally {
      _checkingIncomingShare = false;
    }
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: _SettingsScreen(
          darkMode: widget.darkMode,
          onDarkModeChanged: widget.onDarkModeChanged,
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('DocsGrid', style: TextStyle(fontWeight: FontWeight.w700)),
          if (_selectedIndex == 1)
            IconButton(
              key: const ValueKey('docsgrid-home-reminder-bell'),
              tooltip: 'Document reminders',
              onPressed: _showReminderCenter,
              icon: Stack(clipBehavior: Clip.none, children: [
                const Icon(Icons.notifications_none_outlined),
                if (_dueReminderCount > 0)
                  Positioned(
                    top: -7, right: -10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.error,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Center(child: Text(
                        _dueReminderCount > 9 ? '9+' : '$_dueReminderCount',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                            color: Theme.of(context).colorScheme.onError),
                      )),
                    ),
                  ),
              ]),
            ),
        ]),
        actions: _selectedIndex == 1
            ? [
                IconButton(
                  tooltip: widget.darkMode ? 'Switch to light theme' : 'Switch to dark theme',
                  onPressed: () => widget.onDarkModeChanged(!widget.darkMode),
                  icon: Icon(widget.darkMode ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
                ),
                IconButton(
                  tooltip: 'Settings',
                  onPressed: _openSettings,
                  icon: const Icon(Icons.settings_outlined),
                ),
                const SizedBox(width: 6),
              ]
            : _selectedIndex == 0 && Platform.isIOS
                ? [
                    IconButton(
                      tooltip: 'Choose Apple Files folder',
                      icon: const Icon(Icons.folder_open_outlined),
                      onPressed: _chooseIosPhoneFilesFolder,
                    ),
                  ]
                : const [],
      ),
      body: SafeArea(
        child: IndexedStack(
          index: _selectedIndex,
          children: [
            _visitedTabs.contains(0)
                ? DocumentsScreen(
                    key: Platform.isIOS
                        ? ValueKey('phone-tab-ios-$_iosPhoneBrowseRevision')
                        : const ValueKey('phone-tab'),
                    phoneOnly: true,
                    active: _selectedIndex == 0,
                    onBackAtRoot: _returnToHomeFromStorage,
                  )
                : const SizedBox.shrink(),
            DocumentsScreen(
              key: const ValueKey('home-tab'),
              active: _selectedIndex == 1,
              onBackAtRoot: _backgroundApp,
            ),
            _visitedTabs.contains(2)
                ? FoldersScreen(
                    key: const ValueKey('grid-tab'),
                    active: _selectedIndex == 2,
                    onBackAtRoot: _returnToHomeFromStorage,
                    onOpenSettings: _openSettings,
                  )
                : const SizedBox.shrink(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          if (index == _selectedIndex) return;
          setState(() {
            _visitedTabs.add(index);
            _selectedIndex = index;
          });
          if (index == 1) unawaited(_refreshReminderBadge());
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.phone_android_outlined), label: 'Phone'),
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.folder_outlined), label: 'Grid'),
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
  bool _checkingStorage = false;

  @override
  void initState() {
    super.initState();
    // Keep the internal permission/provider health check after hiding its tile.
    unawaited(_refreshStorageStatus());
  }

  Future<void> _refreshStorageStatus() async {
    if (_checkingStorage) return;
    _checkingStorage = true;
    try {
      await StorageLocationService.instance.checkStorageAccess();
    } catch (error) {
      unawaited(DiagnosticLogStore.instance.recordError(
          'Storage access health check', error));
    } finally {
      _checkingStorage = false;
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
          title: const Text('Copy existing PDF library?'),
          content: Text(
            'Use “${folder['name']}” for new imports and copy your existing PDFs and folder structure there? '
            'Every PDF is verified. All original files remain untouched.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('New imports only'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Copy existing library'),
            ),
          ],
        ),
      );
      if (!context.mounted) return;
      await _refreshStorageStatus();
      if (!context.mounted) return;
      if (migrate != true) {
        messenger.showSnackBar(
          SnackBar(content: Text('Storage folder selected: ${folder['name']}. Existing PDFs were left unchanged.')),
        );
        return;
      }

      var completed = 0;
      var total = 0;
      var current = 'Preparing verified copies…';
      StateSetter? updateProgress;
      final progressDialog = showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            updateProgress = setDialogState;
            final value = total == 0 ? null : completed / total;
            return AlertDialog(
              title: const Text('Copying PDF library'),
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
                  const Text('Keep DocsGrid open. Original files are never deleted during library copying.'),
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
            SnackBar(content: Text('Library copy completed: $count PDFs verified. Originals retained.')),
          );
        }
      } catch (error) {
        if (context.mounted) {
          Navigator.of(context, rootNavigator: true).pop();
          await progressDialog;
          messenger.showSnackBar(
            SnackBar(content: Text('Library copy stopped safely: $error')),
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

  Widget _sectionTitle(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
        child: Text(
          title,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.7,
              ),
        ),
      );

  Future<void> _recoverPreviousInstallation() async {
    if (!Platform.isAndroid) return;
    final storage = StorageLocationService.instance;
    try {
      final known = await storage.discoverOldDocsGridStorage();
      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Recover previous DocsGrid installation'),
          content: const Text(
              'Choose a read-only old DocsGrid source. Your current Grid '
              'storage and existing backup folder will not be switched.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'),
                child: const Text('Cancel')),
            if (known != null)
              TextButton(onPressed: () => Navigator.pop(ctx, 'old'),
                  child: const Text('From old Storage location')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'choose'),
                child: const Text('Choose another location')),
          ],
        ),
      );
      if (!mounted) return;
      final source = choice == 'old' ? known :
          choice == 'choose' ? await storage.chooseRecoveryFolder() : null;
      if (source == null || !mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Restore previous DocsGrid data')),
          body: DocumentToolsScreen(
            quickAction: 'restore_selected_portable',
            initialRecoverySource: source,
            section: 'backup_restore',
          ),
        ),
      ));
    } catch (error) {
      unawaited(DiagnosticLogStore.instance.recordError(
          'Recover previous installation', error));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Old storage could not be opened: $error')));
      }
    }
  }

  Widget _settingsCard(List<Widget> children) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: Theme.of(context).dividerColor.withOpacity(0.35),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      );

  @override
  Widget build(BuildContext context) {
    final mutedDivider = Divider(
      height: 1,
      indent: 64,
      color: Theme.of(context).dividerColor.withOpacity(0.35),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        _sectionTitle('PREFERENCES'),
        _settingsCard([
          SwitchListTile(
            secondary: const Icon(Icons.dark_mode_outlined),
            title: const Text('Dark appearance', style: TextStyle(fontWeight: FontWeight.w600)),
            value: widget.darkMode,
            onChanged: widget.onDarkModeChanged,
          ),
          mutedDivider,
          const ListTile(
            leading: Icon(Icons.view_agenda_outlined),
            title: Text('Default view', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text('List'),
            trailing: Icon(Icons.chevron_right),
          ),
          mutedDivider,
          ListTile(
            leading: const Icon(Icons.sd_storage_outlined),
            title: const Text('Choose storage location', style: TextStyle(fontWeight: FontWeight.w600)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _chooseStorage(context),
          ),
        ]),

        _sectionTitle('DATA'),
        _settingsCard([
          ListTile(
            leading: const Icon(Icons.backup_outlined),
            title: const Text('Backup & Recovery', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Create backup · Restore backup'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('Backup & Recovery')),
              body: const DocumentToolsScreen(section: 'backup_restore'),
            ))),
          ),
          if (Platform.isAndroid) ...[
            mutedDivider,
            ListTile(
              leading: const Icon(Icons.folder_copy_outlined),
              title: const Text('Recover previous installation',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Choose an old storage source without changing the active folder.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _recoverPreviousInstallation,
            ),
          ],
          mutedDivider,
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Activity', style: TextStyle(fontWeight: FontWeight.w600)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HistoryScreen())),
          ),
          mutedDivider,
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: const Text('Reminder', style: TextStyle(fontWeight: FontWeight.w600)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RemindersScreen())),
          ),
          mutedDivider,
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('Smart Collections', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Saved filters for categories, tags, starred and recent PDFs'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const SmartCollectionsScreen(),
            )),
          ),
          mutedDivider,
          ListTile(
            leading: const Icon(Icons.sell_outlined),
            title: const Text('Category & Tag', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Labels to organise your PDFs'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('Category & Tag')),
              body: const CategoriesScreen(),
            ))),
          ),
        ]),
      ],
    );
  }
}
