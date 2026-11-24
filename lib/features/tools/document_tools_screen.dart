import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/database/app_database.dart';
import '../../core/backup/backup_automation.dart';
import '../../core/diagnostics/diagnostic_log_store.dart';
import '../../core/storage/byte_stream_file.dart';
import '../../core/storage/storage_location_service.dart';
import '../documents/data/document_repository.dart';
import 'document_tools_service.dart';
import 'backup_chain.dart';
import 'pdf_recovery_failure_report.dart';
import 'recovery_result_dialog.dart';

class DocumentToolsScreen extends StatefulWidget {
  const DocumentToolsScreen({super.key, this.quickAction, this.section = 'tools',
    this.service, this.forceAndroidBackupForTesting = false,
    this.initialRecoverySource});
  final String? quickAction;
  final String section;
  /// Read-only old source selected by the fresh-install recovery chooser.
  /// This never changes the active DocsGrid storage configuration.
  final Map<String, String>? initialRecoverySource;
  @visibleForTesting
  final DocumentToolsService? service;
  /// Test-only switch: production continues to use dart:io Platform.isAndroid.
  @visibleForTesting
  final bool forceAndroidBackupForTesting;

  @override
  State<DocumentToolsScreen> createState() => _DocumentToolsScreenState();
}

class _DocumentToolsScreenState extends State<DocumentToolsScreen>
    with WidgetsBindingObserver {
  late final DocumentToolsService _tools;
  final _search = TextEditingController();
  bool _searching = false;
  int _searchGeneration = 0;
  List<Map<String, Object?>> _results = [];
  bool _busy = false;
  String? _message;
  bool _hasSearched = false;
  bool _awaitingAllFilesPermission = false;
  bool _resumeAutoDetect = true;
  Map<String, String>? _resumeRecoverySource;
  List<BackupChainUsage> _manualBackupSets = const [];
  bool _backupUsageReady = false;
  DateTime? _lastDatabaseBackup;
  double? _backupProgress;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tools = widget.service ?? DocumentToolsService();
    if (widget.section == 'backup' || widget.section == 'restore' ||
        widget.section == 'backup_restore') {
      unawaited(_refreshBackupUsage());
      unawaited(_refreshDatabaseStatus());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (widget.quickAction) {
        case 'backup': _backup(); break;
        case 'restore_portable': _restorePortableSnapshot(autoDetect: true); break;
        case 'restore_selected_portable': _restorePortableSnapshot(
            selectedSource: widget.initialRecoverySource); break;
        case 'restore_latest_backup': _restoreNewestPortableBackup(); break;
        case 'recover_loose_pdfs': _recoverLoosePortablePdfs(); break;
      }
    });
  }

  Future<void> _run(Future<void> Function() action,
      {bool recoveryOperation = false}) async {
    if (!mounted || _busy) return;
    setState(() { _busy = true; _message = null; _backupProgress = null; });
    try {
      await action();
    } catch (e) {
      unawaited(DiagnosticLogStore.instance.recordError(
          'Tools ${widget.section}', e));
      if (mounted) {
        if (recoveryOperation) {
          await _showRecoveryResult(RecoveryResultData.failure(e));
        } else {
          setState(() => _message = 'Action could not be completed: $e');
        }
      }
    } finally {
      if (mounted) setState(() { _busy = false; _backupProgress = null; });
    }
  }

  Future<void> _showRecoveryResult(RecoveryResultData result) async {
    if (!mounted) return;
    // Keep just a one-line status behind the popup; full output is expandable.
    setState(() => _message = '${result.title}. ${result.subtitle}');
    await showRecoveryResultDialog(context, result);
  }

  Future<void> _refreshBackupUsage() async {
    try {
      final sets = await _tools.manualBackupUsage()
          .timeout(const Duration(seconds: 20));
      if (mounted) setState(() {
        _manualBackupSets = sets;
        _backupUsageReady = true;
      });
    } catch (_) {
      if (mounted) setState(() => _backupUsageReady = false);
    }
  }

  Future<void> _refreshDatabaseStatus() async {
    try {
      final status = await BackupAutomation.readStatus(full: false);
      final completed = DateTime.tryParse(status['completedAtUtc'] as String? ?? '');
      if (mounted && completed != null &&
          (_lastDatabaseBackup == null || completed.isAfter(_lastDatabaseBackup!))) {
        setState(() => _lastDatabaseBackup = completed.toLocal());
      }
    } catch (_) {
      // Optional status must not block backup or recovery.
    }
  }

  Future<void> _backup() => _run(() async {
    if (mounted) setState(() => _message = 'Checking library and available storage…');
    final preview = await _tools.fullBackupPreview();
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create Full Backup'),
        content: SingleChildScrollView(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Create one independent ZIP for your DocsGrid library.'),
            const SizedBox(height: 12),
            for (final entry in <String, String>{
              'PDF records': '${preview['documents']}',
              'Folders & subfolders': '${preview['folders']}',
              'Categories': '${preview['categories']}',
              'Tags': '${preview['tags']}',
              'Reminders': '${preview['reminders']}',
              'Database & supported settings': 'Included',
              'Registered PDF size': _formatSize(preview['pdfBytes'] ?? 0),
              if (preview.containsKey('availableBytes'))
                'Available storage': _formatSize(preview['availableBytes']!),
            }.entries)
              Padding(padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Expanded(child: Text(entry.key)),
                  const SizedBox(width: 8),
                  Text(entry.value),
                ])),
            const Divider(),
            const Text('The final ZIP size may differ. Phone Storage PDFs, cache '
                'and temporary files are excluded. Current ZIP limit: 2 GB. '
                'Export a verified copy outside this phone for protection if it is lost.'),
          ],
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Create Backup')),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      if (mounted) setState(() => _message = null);
      return;
    }
    setState(() => _message = 'Preparing verified Full backup…');
    final archive = await _tools.createStandaloneFullBackup(
      onStage: (stage) {
        if (mounted) setState(() {
          _message = stage;
          _backupProgress = null;
        });
      },
      onProgress: (completed, total) {
        if (!mounted) return;
        setState(() {
          _message = total == 0 ? 'Preparing backup…'
              : 'Checking PDFs: $completed of $total';
          _backupProgress = total > 0
              ? (completed / total).clamp(0.0, 1.0).toDouble() : null;
        });
      },
    );
    if (!mounted) return;
    int? archiveBytes;
    try { archiveBytes = await archive.length(); } catch (_) {}
    if (!mounted) return;
    setState(() => _message =
        'Verified backup created: ${p.basename(archive.path)}');
    // iOS currently has a private backup archive and native export, rather
    // than Android's persistent local Full archive browser. Preserve sharing.
    if (!Platform.isAndroid && !widget.forceAndroidBackupForTesting) {
      await _tools.shareFile(archive.path, text: 'DocsGrid Full backup');
      return;
    }
    unawaited(_refreshBackupUsage());
    final export = await showDialog<bool>(context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.check_circle_outline),
        title: const Text('Backup Successful'),
        content: Text('${p.basename(archive.path)}\n'
            '${archiveBytes == null ? '' : 'Size: ${_formatSize(archiveBytes)}\n'}'
            'Your Full ZIP passed verification. Keep a copy outside this phone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Done')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Export Now')),
        ],
      ));
    if (export == true && mounted) {
      await _exportBackupDestination(p.basename(archive.path));
    }
  });

  Future<void> _exportBackupDestination(String id) async {
    final choice = await showModalBottomSheet<String>(
      context: context, showDragHandle: true,
      builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: Text('Export to')),
          ListTile(leading: const Icon(Icons.folder_open),
            title: const Text('Save to folder'),
            subtitle: const Text('Internal storage, SD card or USB'),
            onTap: () => Navigator.pop(ctx, 'folder')),
          ListTile(leading: const Icon(Icons.ios_share_outlined),
            title: const Text('Share Backup'),
            subtitle: const Text('Google Drive, Quick Share and other apps'),
            onTap: () => Navigator.pop(ctx, 'share')),
        ])),
    );
    if (choice == 'share') {
      await _tools.shareManualBackupSeries(id);
      return;
    }
    if (choice != 'folder' || !mounted) return;
    final selected = await StorageLocationService.instance.chooseBackupExportFolder();
    if (selected == null) return;
    if (mounted) setState(() => _message = 'Exporting verified $id…');
    final bytes = await _tools.exportManualBackupSeries(id, selected['uri']!);
    if (mounted) setState(() => _message =
        'Exported $id successfully (${_formatSize(bytes)}). '
        'The original backup remains unchanged.');
  }

  Future<void> _showCleanBackups() => _run(() async {
    await _refreshBackupUsage();
    if (!mounted) return;
    if (!_backupUsageReady) {
      throw StateError('Backup storage could not be read. Try again.');
    }
    final archives = List<BackupChainUsage>.of(_manualBackupSets);
    if (archives.isEmpty) {
      await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('Clean Backups'),
        content: const Text('No manual backups to clean.'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'))],
      ));
      return;
    }
    final selected = <String>{};
    final ids = await showDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, refresh) => AlertDialog(
        title: const Text('Clean Backups'),
        content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min,
          children: [
            CheckboxListTile(
              title: const Text('Select All'),
              value: selected.length == archives.length,
              onChanged: (v) => refresh(() {
                selected.clear();
                if (v == true) selected.addAll(archives.map((a) => a.name));
              }),
            ),
            Flexible(child: ListView(shrinkWrap: true, children: [
              for (final item in archives)
                CheckboxListTile(
                  title: Text(item.name),
                  subtitle: Text('${_formatSize(item.bytes)} · ${item.files} ZIP files'),
                  value: selected.contains(item.name),
                  onChanged: (v) => refresh(() {
                    if (v == true) {
                      selected.add(item.name);
                    } else {
                      selected.remove(item.name);
                    }
                  }),
                ),
            ])),
            Text('Selected: ${selected.length} · ${_formatSize(archives.where((a) => selected.contains(a.name)).fold<int>(0, (n, a) => n + a.bytes))}'),
            const Text('Original PDFs, folders and database will not be touched. '
                'Older series are deleted only as complete sets.'),
          ],
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: selected.isEmpty ? null
              : () => Navigator.pop(ctx, Set<String>.of(selected)),
              child: const Text('Delete Selected')),
        ],
      )),
    );
    if (ids == null || ids.isEmpty || !mounted) return;
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Delete selected backups?'),
      content: Text('Permanently delete ${ids.length} selected backup(s)? '
          'Original PDFs, folders and automatic database backups are unchanged.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
      ],
    ));
    if (confirmed != true || !mounted) return;
    var deleted = 0;
    final failures = <String>[];
    for (final id in ids) {
      try {
        await _tools.deleteManualBackupSeries(id);
        deleted++;
      } catch (e) {
        failures.add(id);
        unawaited(DiagnosticLogStore.instance.recordError('Clean backup $id', e));
      }
    }
    if (mounted) setState(() => _message =
        'Deleted $deleted backup(s). My Files was not changed.'
        '${failures.isEmpty ? '' : ' Could not delete: ${failures.join(', ')}'}');
    unawaited(_refreshBackupUsage());
  });

  Future<void> _showExportBackups() => _run(() async {
    await _refreshBackupUsage();
    if (!mounted) return;
    if (!_backupUsageReady) {
      setState(() => _message = 'Backup storage could not be read. Try again.');
      return;
    }
    final archives = List<BackupChainUsage>.of(_manualBackupSets);
    String? selected = archives.isEmpty ? null : archives.first.name;
    final choice = await showDialog<String>(context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, refresh) => AlertDialog(
        title: const Text('Export Backup'),
        content: SizedBox(width: 420, child: archives.isEmpty
          ? const Text('No manual backups available.')
          : ListView(shrinkWrap: true, children: [
            for (final item in archives)
              ListTile(
                leading: Icon(selected == item.name
                    ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                title: Text(item.name),
                subtitle: Text('${_formatSize(item.bytes)} · ${item.files} ZIP files'),
                onTap: () => refresh(() => selected = item.name),
              ),
          ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: selected == null ? null
              : () => Navigator.pop(ctx, selected), child: const Text('Continue')),
        ],
      )));
    if (choice != null && mounted) await _exportBackupDestination(choice);
  });

  Future<void> _databaseBackup() => _run(() async {
    if (mounted) setState(() => _message = 'Creating Database Backup…');
    final archive = await _tools.createBackup(includePdfs: false);
    final completed = DateTime.now();
    try {
      await BackupAutomation.recordManualDatabaseBackup(archive, completed);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _lastDatabaseBackup = completed;
      _message = 'Database backup verified. PDF contents are not included.';
    });
    final share = await showDialog<bool>(context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.check_circle_outline),
        title: const Text('Database Backup Successful'),
        content: const Text('Document records, folders and supported metadata '
            'were saved. Actual PDF contents are not included.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Done')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Share Backup')),
        ],
      ));
    if (share == true && mounted) {
      await _tools.shareFile(archive.path, text: 'DocsGrid database backup');
    }
  });

  Future<void> _showEmergencyRecovery() async {
    if (_busy) return;
    final source = await showModalBottomSheet<String>(
      context: context, showDragHandle: true,
      builder: (ctx) => SafeArea(child: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Emergency Recovery'),
            subtitle: Text('Original files will not be deleted or overwritten.')),
          ListTile(leading: const Icon(Icons.folder_open),
            title: const Text('Scan DocsGrid Storage'),
            subtitle: const Text('Find existing folders, PDFs and recovery metadata.'),
            onTap: () => Navigator.pop(ctx, 'scan')),
          ListTile(leading: const Icon(Icons.folder_outlined),
            title: const Text('Choose Folder'),
            subtitle: const Text('Select a previous DocsGrid storage folder.'),
            onTap: () => Navigator.pop(ctx, 'old')),
          ListTile(leading: const Icon(Icons.picture_as_pdf_outlined),
            title: const Text('PDF folder'),
            subtitle: const Text('Recover existing PDFs without deleting originals.'),
            onTap: () => Navigator.pop(ctx, 'pdf')),
          ExpansionTile(title: const Text('Older backup formats'), children: [
            ListTile(leading: const Icon(Icons.folder_zip_outlined),
              title: const Text('Incremental series folder'),
              subtitle: const Text('Restore an existing A-series with all parent ZIPs.'),
              onTap: () => Navigator.pop(ctx, 'series')),
          ]),
        ],
      ))),
    );
    if (!mounted) return;
    switch (source) {
      case 'scan': await _restorePortableSnapshot(autoDetect: true); break;
      case 'old': await _restorePortableSnapshot(); break;
      case 'pdf': await _recoverSelectedPdfFolder(); break;
      case 'series': await _restoreBackup(source: 'series'); break;
    }
  }

  Future<bool> _confirmRestorePlan(Map<String, int> plan) async {
    if (!mounted) return false;
    return await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('Verified restoration preview'),
      content: Text('Folders in selection: ${plan['folders']}\n'
          'Verified existing folders: ${plan['matchedFolders']}\n'
          'New physical folders: ${plan['newFolders']}\n'
          'Document records: ${plan['documents']}\n'
          'Verified existing PDFs: ${plan['verifiedPdfs']}\n'
          'New PDFs to copy: ${plan['newPdfs']}\n'
          'Needs relinking: ${plan['needsRelinking']}\n'
          'Legacy folder mappings to repair: ${plan['legacyFolderRepairs'] ?? 0}\n'
          'Existing legacy PDFs to copy safely: ${plan['legacyPdfsToCopy'] ?? 0}\n'
          'Existing PDFs reused after verification: ${plan['legacyPdfsReused'] ?? 0}\n'
          'Old Restored_ folders and their source PDFs will NOT be deleted. '
          'Approving this preview permits verified copies and SQLite relinking '
          'to the original folder.\n'
          'Conflicts: ${plan['conflicts']}'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Apply restore')),
      ],
    )) ?? false;
  }

  Future<void> _recoverSelectedPdfFolder() => _run(() async {
    final selected = await StorageLocationService.instance
        .choosePdfRecoveryFolder();
    if (selected == null) return;
    final failures = PdfRecoveryFailureReport();
    final result = await _tools.recoverLoosePortablePdfs(
      additionalFolderUri: selected['uri'],
      onFailure: failures.record,
      onProgress: (completed, total) {
        if (mounted) setState(() => _message =
            'Finding PDFs: $completed of $total');
      },
    );
    await _showRecoveryResult(RecoveryResultData.fromPdfFolder(
      result,
      failureReasons: failures.totalFailures > 0 ? failures.summary : null,
    ));
  }, recoveryOperation: true);

  Future<void> _restoreBackup({String source = 'zip'}) => _run(() async {
    if (source != 'zip' && source != 'series') return;
    if (Platform.isAndroid) {
      if (mounted) setState(() => _message =
          'Checking restore access and existing DocsGrid folders…');
      try {
        await StorageLocationService.instance.zipRestoreFileLocations();
      } on StateError catch (error) {
        if (!error.toString().contains('Full internal storage access is currently disabled')) {
          rethrow;
        }
        if (!mounted) return;
        final openSettings = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('ZIP restore needs storage access'),
            content: const Text(
              'Android reports that Full internal storage access is OFF for this installation. '
              'Allow it in Android Settings. Your PDFs and existing database '
              'have not been changed. Then return and choose Restore again.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Not now')),
              FilledButton(onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Open settings')),
            ],
          ),
        );
        if (openSettings == true) {
          if (mounted) setState(() => _message =
              'Open Android Settings, allow DocsGrid full storage access, '
              'then return and choose Restore again.');
          await StorageLocationService.instance.requestAllFilesAccess();
        } else if (mounted) {
          setState(() => _message = 'Restore cancelled. Nothing was changed.');
        }
        return;
      }
    }
    if (mounted) setState(() => _message =
        source == 'series' ? 'Choose your A-series backup folder…'
            : 'Choose the ZIP backup to restore…');
    final chosenSeriesFolder = source == 'series'
        ? await StorageLocationService.instance.chooseBackupChainFolder()
        : null;
    if (source == 'series' && chosenSeriesFolder == null) return;
    final stagedSeriesFile = source == 'series'
        ? await _tools.stageSelectedBackupChain(chosenSeriesFolder!['uri']!)
        : null;
    final platformFile = source == 'zip'
        ? await FilePicker.pickFile(
            type: FileType.custom, allowedExtensions: ['zip'])
        : null;
    if (source == 'zip' && platformFile == null) {
      if (mounted) setState(() => _message =
          'Restore cancelled. Nothing was changed.');
      return;
    }
    final temporaryCopy = source == 'zip' &&
        (platformFile!.path == null || platformFile.path!.isEmpty);
    final temporaryDirectory =
        temporaryCopy ? await getTemporaryDirectory() : null;
    final file = stagedSeriesFile ?? (temporaryCopy
        ? File(p.join(temporaryDirectory!.path,
            'DocsGrid_restore_${DateTime.now().microsecondsSinceEpoch}.zip'))
        : File(platformFile!.path!));
    try {
      if (mounted) setState(() => _message =
          temporaryCopy ? 'Copying the selected ZIP to temporary storage…'
              : 'Preparing the selected backup ZIP…');
      if (temporaryCopy) {
        // Backup ZIPs may contain many large PDFs. Stage provider data as a
        // stream rather than materializing the entire archive in RAM.
        await writeByteStreamToFile(platformFile.readAsByteStream(), file);
      }
      if (!mounted) return;
      final restoreMode = await showDialog<BackupRestoreMode>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Choose restore mode'),
          content: const Text(
            'Merge keeps current records and adds backup data. Full replacement first creates a safety backup, then replaces the current DocsGrid database.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, BackupRestoreMode.merge),
              child: const Text('Merge'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, BackupRestoreMode.selective),
              child: const Text('Selective'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, BackupRestoreMode.fullReplacement),
              child: const Text('Full replacement'),
            ),
          ],
        ),
      );
      if (restoreMode == null || !mounted) {
        if (mounted) setState(() => _message = 'Restore cancelled. Nothing was changed.');
        return;
      }
      Set<BackupRestoreSection>? selection;
      if (restoreMode == BackupRestoreMode.selective) {
        final selected = <BackupRestoreSection>{
          BackupRestoreSection.documents,
          BackupRestoreSection.reminders,
          BackupRestoreSection.history,
          BackupRestoreSection.settings,
        };
        selection = await showDialog<Set<BackupRestoreSection>>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
            builder: (dialogContext, refresh) => AlertDialog(
              title: const Text('Select data to restore'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final item in BackupRestoreSection.values)
                      CheckboxListTile(
                        dense: true,
                        value: selected.contains(item),
                        title: Text(switch (item) {
                          BackupRestoreSection.documents => 'PDFs and document records',
                          BackupRestoreSection.folders => 'Folders',
                          BackupRestoreSection.categories => 'Categories',
                          BackupRestoreSection.tags => 'Tags',
                          BackupRestoreSection.reminders => 'Reminders',
                          BackupRestoreSection.history => 'Activity and history',
                          BackupRestoreSection.settings => 'Settings',
                          BackupRestoreSection.smartCollections => 'Smart Collections',
                          BackupRestoreSection.ocrIndexes => 'OCR search indexes',
                        }),
                        onChanged: (checked) => refresh(() {
                          if (checked == true) {
                            selected.add(item);
                          } else {
                            selected.remove(item);
                          }
                        }),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () => Navigator.pop(dialogContext, Set.of(selected)),
                  child: const Text('Continue'),
                ),
              ],
            ),
          ),
        );
        if (selection == null || selection.isEmpty || !mounted) {
          if (mounted) setState(() => _message = 'Restore cancelled. Nothing was changed.');
          return;
        }
      }
      if (mounted) setState(() => _message = 'Waiting for the verified restore operation…');
      final restored = await _tools.restoreBackup(
        file,
        mode: restoreMode,
        selection: selection,
        confirmPlan: _confirmRestorePlan,
        onProgress: (message) {
          if (mounted) setState(() => _message = message);
        },
        confirm: (count) async {
          if (!mounted) return false;
          return await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Restore backup?'),
                  content: Text(
                    restoreMode == BackupRestoreMode.fullReplacement
                        ? 'The archive contains $count PDF file(s). DocsGrid will first create a full safety backup, then replace the current database. Existing shared PDFs are not automatically deleted.'
                        : restoreMode == BackupRestoreMode.selective
                            ? 'The archive contains $count PDF file(s). Only the data groups you selected will be imported; current records are preserved.'
                            : 'The archive contains $count PDF file(s). Existing records will be kept; the backup will be merged without overwriting your current files.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Restore'),
                    ),
                  ],
                ),
              ) ??
              false;
        },
      );
      Map<String, int>? relink;
      if (restored == 0 && Platform.isAndroid) {
        // Database-only restore must reconnect surviving PDF bytes to their
        // original tags, reminders, and category records automatically.
        relink = await _tools.recoverLoosePortablePdfs(
          onProgress: (completed, total) {
            if (mounted) setState(() => _message =
                'Reconnecting PDFs: $completed of $total');
          },
        );
      }
      if (restored == null) {
        if (mounted) setState(() => _message = 'Restore cancelled. Nothing was changed.');
      } else {
        await _showRecoveryResult(
            RecoveryResultData.fromArchive(restored, scanned: relink));
      }
    } on StateError catch (error) {
      if (!error.toString().contains('contains no user PDFs') || !mounted) rethrow;
      final recover = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('This backup has no Grid data'),
          content: Text(
            '${error.toString()}\n\nYou can rebuild the PDF library from files '
            'still present in the DocsGrid storage folders. Original source PDFs will not be deleted.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Recover existing PDFs'),
            ),
          ],
        ),
      );
      if (recover == true && mounted) {
        final result = await _tools.recoverLoosePortablePdfs(
          onProgress: (completed, total) {
            if (mounted) setState(() => _message = 'Recovering PDFs: $completed of $total');
          },
        );
        await _showRecoveryResult(RecoveryResultData.fromPdfFolder(result));
      } else {
        rethrow;
      }
    } finally {
      if (temporaryCopy && await file.exists()) await file.delete();
      if (stagedSeriesFile != null) {
        try {
          await stagedSeriesFile.parent.parent.delete(recursive: true);
        } catch (_) {}
      }
    }
  }, recoveryOperation: true);

  Future<void> _recoverLoosePortablePdfs() => _run(() async {
    final recovered = await _tools.recoverLoosePortablePdfs(
      onProgress: (completed, total) {
        if (mounted) {
          setState(() => _message = 'Recovering PDFs: $completed of $total');
        }
      },
    );
    await _showRecoveryResult(RecoveryResultData.fromPdfFolder(recovered));
  }, recoveryOperation: true);

  Future<void> _restoreNewestPortableBackup() =>
      _run(_restoreNewestPortableBackupBody, recoveryOperation: true);

  Future<void> _restoreNewestPortableBackupBody({
    Map<String, String>? sourceLocations,
  }) async {
    final candidates = await _tools.listPortableBackupArchives(
        sourceLocations: sourceLocations);
    if (candidates.isEmpty) {
      throw StateError('No portable DocsGrid backup ZIP was found.');
    }
    if (!mounted) return;
    try {
      final restored = await _tools.restoreNewestPortableBackup(
        sourceLocations: sourceLocations,
        confirmPlan: _confirmRestorePlan,
        confirm: (count) async {
          if (!mounted) return false;
          return await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Restore latest backup?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Restore'),
                    ),
                  ],
                ),
              ) ??
              false;
        },
      );
      if (restored != null) {
        Map<String, int>? scanned;
        String? scanProblem;
        if (restored == 0 && Platform.isAndroid) {
          try {
            scanned = await _tools.recoverLoosePortablePdfs(
              additionalFolderUri: sourceLocations?['libraryUri'],
              additionalDocumentsUri: sourceLocations?['documentsUri'],
              onProgress: (completed, total) {
                if (mounted) setState(() => _message =
                    'Reconnecting PDFs: $completed of $total');
              },
            );
          } catch (error) {
            // The successfully restored metadata must not be reported as a
            // failed ZIP restore just because PDF storage is not accessible.
            scanProblem = error.toString();
          }
        }
        await _showRecoveryResult(RecoveryResultData.fromArchive(
            restored, scanned: scanned, scanWarning: scanProblem));
      }
    } catch (error) {
      if (!mounted) rethrow;
      final useLoosePdfs = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('No backup with recoverable data found'),
          content: Text(
            'No backup archive with user data was found. A ZIP may be readable but '
            'contain only default categories and no PDFs or folders. You can rebuild '
            'the Grid library from PDFs retained in the existing DocsGrid storage folders; categories, tags, reminders, '
            'history and settings require a non-empty DocsGrid backup.\n\n$error',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Find DocsGrid PDFs'),
            ),
          ],
        ),
      );
      if (useLoosePdfs == true) {
        final recovered = await _tools.recoverLoosePortablePdfs(
          additionalFolderUri: sourceLocations?['libraryUri'],
          additionalDocumentsUri: sourceLocations?['documentsUri'],
          onProgress: (completed, total) {
            if (mounted) setState(() => _message = 'Recovering PDFs: $completed of $total');
          },
        );
        await _showRecoveryResult(RecoveryResultData.fromPdfFolder(recovered));
      }
    }
  }

  Future<void> _restorePortableSnapshot({
    bool autoDetect = false,
    Map<String, String>? selectedSource,
  }) => _run(() async {
    final storage = StorageLocationService.instance;
    Map<String, String>? recoverySource = selectedSource;
    // A readable source SAF grant is not a writable active Grid destination.
    // Both selected-source and auto-detected recovery need this preflight.
    if (Platform.isAndroid && !await storage.hasAllFilesAccess()) {
      if (!mounted) return;
      final allow = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Allow storage access to restore'),
          content: const Text('Android removes storage permission after a clean '
              'reinstall. Allow DocsGrid full internal storage access, then return. '
              'Recovery will continue using your existing folders and PDFs. '
              'No original files will be deleted.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Not now')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Open settings')),
          ],
        ),
      );
      if (allow != true || !mounted) return;
      _resumeAutoDetect = autoDetect;
      _resumeRecoverySource = selectedSource;
      _awaitingAllFilesPermission = true;
      if (mounted) setState(() => _message =
          'Allow Full internal storage access and return to resume recovery.');
      try {
        await storage.requestAllFilesAccess();
      } catch (_) {
        _awaitingAllFilesPermission = false;
        rethrow;
      }
      return;
    }
    if (autoDetect) {
      await storage.portableDataLocations();
      if (Platform.isAndroid) {
        // Prefer the old managed root, even when the new active root is empty.
        recoverySource ??= await storage.discoverOldDocsGridStorage();
      }
    } else if (recoverySource == null) {
      recoverySource = await storage.chooseRecoveryFolder();
      if (recoverySource == null) return;
    }
    final snapshot = await _tools.verifyLatestPortableMetadataSnapshot(
        sourceLocations: recoverySource);
    if (snapshot == null && recoverySource != null) {
      // On external SAF the existing Incremental picker is the only flow
      // that stages and verifies every A-series parent. Do not pretend an
      // incomplete or invisible external chain is an empty PDF folder.
      final fullUri = recoverySource['fullBackupsUri'];
      if (fullUri != null && fullUri.startsWith('content://')) {
        final possibleSeries = await storage.listDirectory(fullUri);
        final hasExternalChain = possibleSeries.any((item) =>
            item['isDirectory'] == true &&
            BackupChain.validSeriesName(item['name'] as String? ?? ''));
        if (hasExternalChain) {
          if (mounted) setState(() => _message =
              'An old A-series backup folder was found. To recover it safely, '
              'choose Emergency Recovery → Older backup formats → Incremental series folder, then select '
              'the A001 (or relevant A-series) folder. All parent ZIPs will '
              'be verified before restore; nothing has been changed.');
          return;
        }
      }
      // A previous installation may have only a standalone ZIP or no
      // completed metadata snapshot. Verify full ZIPs before bare PDF import.
      final olderArchives = await _tools.listPortableBackupArchives(
          sourceLocations: recoverySource);
      if (olderArchives.isNotEmpty) {
        await _restoreNewestPortableBackupBody(
            sourceLocations: recoverySource);
        return;
      }
    }
    if (snapshot == null && recoverySource == null && autoDetect) {
      final archives = await _tools.listPortableBackupArchives();
      if (archives.isNotEmpty) {
        await _restoreNewestPortableBackupBody();
        return;
      }
    }
    if (snapshot == null) {
      if (!Platform.isAndroid) {
        throw StateError('No verified DocsGrid snapshot was found in the selected folder.');
      }
      final failures = PdfRecoveryFailureReport();
      final recovered = await _tools.recoverLoosePortablePdfs(
        additionalFolderUri: recoverySource?['libraryUri'],
        additionalDocumentsUri: recoverySource?['documentsUri'],
        onFailure: failures.record,
        onProgress: (completed, total) {
          if (mounted) setState(() => _message = 'Recovering PDFs: $completed of $total');
        },
      );
      await _showRecoveryResult(RecoveryResultData.fromPdfFolder(
        recovered,
        failureReasons: failures.totalFailures > 0 ? failures.summary : null,
        note: 'Other app metadata requires a verified snapshot or backup.',
      ));
      return;
    }
    if (!mounted) return;
    final androidNote = Platform.isAndroid
        ? 'Choose the existing DocsGrid folder or its parent. The app will verify all four folders and at least one snapshot; it will not create missing folders.'
        : 'Choose the existing DocsGrid data folder; missing folders or snapshots are rejected without creating a new tree.';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restore DocsGrid folder data?'),
        content: Text(
          'Verified snapshot: $snapshot\n\n$androidNote\n'
          'Existing records will be retained. Imported IDs will be remapped if needed. '
          'PDFs will be matched by SHA-256; files not found will keep their metadata '
          'and be marked for relinking. No PDF file will be overwritten or deleted.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Restore')),
        ],
      ),
    );
    if (confirmed != true) return;
    Map<String, int> result;
    try {
      result = await _tools.restoreLatestPortableMetadataSnapshot(
        sourceLocations: recoverySource,
        onProgress: (completed, total) {
          if (mounted) {
            setState(() => _message = 'Matching snapshot PDFs: $completed of $total');
          }
        },
      );
    } catch (error) {
      if (!Platform.isAndroid || !mounted) rethrow;
      unawaited(DiagnosticLogStore.instance.recordError(
          'Metadata recovery fallback', error));
      // A failed snapshot must not skip a potentially usable database ZIP.
      // The existing ZIP restore flow verifies and previews before mutation.
      try {
        final archives = await _tools.listPortableBackupArchives(
            sourceLocations: recoverySource);
        if (archives.isNotEmpty && mounted) {
          await _restoreNewestPortableBackupBody(sourceLocations: recoverySource);
          return;
        }
      } catch (archiveError) {
        unawaited(DiagnosticLogStore.instance.recordError(
            'Archive recovery fallback', archiveError));
      }
      if (!mounted) return;
      final recoverPdfs = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Recover folders and PDFs instead?'),
          content: const Text('The metadata restore could not be completed. '
              'DocsGrid can still rebuild the folder hierarchy from the '
              'existing PDF library. Tags, reminders and categories may '
              'not be recovered. Original files will not be deleted.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Recover folders and PDFs')),
          ],
        ),
      );
      if (recoverPdfs != true || !mounted) return;
      final failures = PdfRecoveryFailureReport();
      final recovered = await _tools.recoverLoosePortablePdfs(
        additionalFolderUri: recoverySource?['libraryUri'],
        additionalDocumentsUri: recoverySource?['documentsUri'],
        onFailure: failures.record,
        onProgress: (completed, total) {
          if (mounted) setState(() => _message =
              'Recovering PDFs: $completed of $total');
        },
      );
      await _showRecoveryResult(RecoveryResultData.fromPdfFolder(
        recovered,
        failureReasons: failures.totalFailures > 0 ? failures.summary : null,
        note: 'Metadata restoration could not complete; only surviving files and folders were recovered.',
      ));
      return;
    }

    // A portable metadata snapshot can be older than the surviving PDF library
    // (for example, snapshots created by releases which refreshed only after
    // reminder changes). Restore metadata first, then register PDFs which still
    // exist in DocsGrid-managed folders. SHA-256 duplicate checks make this
    // pass safe to repeat; source files are never deleted or overwritten.
    Map<String, int> looseRecovery = const <String, int>{
      'added': 0, 'duplicates': 0, 'failed': 0, 'folders': 0,
    };
    String? looseRecoveryWarning;
    try {
      looseRecovery = await _tools.recoverLoosePortablePdfs(
        additionalFolderUri: recoverySource?['libraryUri'],
        additionalDocumentsUri: recoverySource?['documentsUri'],
        onProgress: (completed, total) {
          if (mounted) {
            setState(() => _message =
                'Recovering remaining DocsGrid PDFs: $completed of $total');
          }
        },
      );
    } catch (error) {
      // Keep the completed metadata restore visible if the extra file scan is
      // blocked by storage permission or a provider failure.
      looseRecoveryWarning = error.toString();
    }

    await _showRecoveryResult(RecoveryResultData.fromSnapshot(
      result, looseRecovery, scanWarning: looseRecoveryWarning,
    ));
  }, recoveryOperation: true);

  Future<void> _openSearchResult(Map<String, Object?> result) async {
    final uri = result['storage_uri']?.toString() ?? '';
    if (uri.isEmpty) return;
    try {
      await StorageLocationService.instance.openPdf(uri, gridPdf: true);
    } catch (error) {
      if (mounted) setState(() => _message = 'Could not open matching PDF: $error');
    }
  }

  Future<void> _searchText() async {
    final query = _search.text.trim();
    if (_searching || query.isEmpty) return;
    final generation = ++_searchGeneration;
    setState(() {
      _searching = true;
      _message = null;
    });
    try {
      final rows = await _tools.searchText(query);
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _results = rows;
        _hasSearched = true;
        _message = null;
      });
    } catch (error, stackTrace) {
      // Keep the full diagnostic in logcat/Flutter logs. The visible message
      // remains concise; swallowing this stack made native/plugin failures
      // impossible to distinguish from widget lifecycle failures.
      debugPrint('DocsGrid OCR search failed for query "$query": $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted && generation == _searchGeneration) {
        setState(() => _message = 'Text search failed. Please retry; diagnostic details were recorded.');
      }
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _indexDocuments() => _run(() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query('documents',
      columns: ['id', 'name', 'storage_uri', 'extracted_text_status'],
      where: 'deleted_at IS NULL');
    var done = 0;
    var noText = 0;
    var skipped = 0;
    var alreadyIndexed = 0;
    for (final row in rows) {
      // Stop background OCR work when the owning route is dismissed.
      if (!mounted) return;
      if (row['extracted_text_status'] == 'indexed') {
        alreadyIndexed++;
        continue;
      }
      final uri = row['storage_uri'] as String?;
      if (uri == null || uri.isEmpty) {
        skipped++;
        continue;
      }
      try {
        final characters = await _tools.indexPdfTextFromUri(
          row['id'] as String,
          uri,
          shouldCancel: () => !mounted,
        );
        if (characters == 0) {
          noText++;
        } else {
          done++;
        }
      } on OcrIndexCancelled {
        // Route disposal is an expected cancellation, not a failed document.
        return;
      } catch (error, stackTrace) {
        skipped++;
        debugPrint('DocsGrid OCR indexing failed for document ${row['id']}: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }
    if (mounted) {
      setState(() => _message =
        'OCR indexing finished: $done searchable, $noText had no readable text, $alreadyIndexed already indexed, $skipped failed. '
        'Scanned/image-only PDFs may need clearer pages or a supported OCR language.');
    }
  });


  Future<void> _reviewDuplicateGroup(List<String> documentIds, String duplicateType) async {
    if (documentIds.length < 2) return;
    final db = await AppDatabase.instance.database;
    final placeholders = List.filled(documentIds.length, '?').join(',');
    final rows = await db.query('documents',
      where: 'id IN ($placeholders) AND deleted_at IS NULL',
      whereArgs: documentIds,
      orderBy: 'created_at ASC');
    final docs = rows.map(DocumentRecord.fromMap).toList();
    if (docs.length < 2 || !mounted) return;
    await showDialog<void>(context: context, builder: (dialogContext) => StatefulBuilder(
      builder: (context, refresh) => AlertDialog(
        title: Text('Duplicate PDFs · $duplicateType'),
        content: SizedBox(width: 440, height: 380, child: Column(children: [
          const Text('Review each matching PDF. Move unwanted copies to Recycle Bin one at a time.'),
          const SizedBox(height: 8),
          Expanded(child: docs.isEmpty
            ? const Center(child: Text('No remaining duplicates in this group.'))
            : ListView.separated(
              itemCount: docs.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final doc = docs[index];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.picture_as_pdf_outlined),
                  title: Text('${doc.name}.pdf', maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(_formatSize(doc.sizeBytes)),
                  onTap: () async {
                    final uri = doc.storagePath;
                    await StorageLocationService.instance.openPdf(uri, gridPdf: true);
                  },
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) async {
                      if (action == 'open') {
                        final uri = doc.storagePath;
                        await StorageLocationService.instance.openPdf(uri, gridPdf: true);
                      } else if (action == 'share') {
                        await _tools.shareStoredPdf(doc.storagePath, '${doc.name}.pdf');
                      } else if (action == 'trash') {
                        final confirmed = await showDialog<bool>(
                          context: dialogContext,
                          builder: (confirmContext) => AlertDialog(
                            title: const Text('Move this copy to Recycle Bin?'),
                            content: Text('${doc.name}.pdf will remain recoverable in Recycle Bin.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(confirmContext, false), child: const Text('Cancel')),
                              FilledButton(onPressed: () => Navigator.pop(confirmContext, true), child: const Text('Move')),
                            ],
                          ),
                        );
                        if (confirmed == true) {
                          await DocumentRepository().moveToTrash(doc);
                          refresh(() => docs.removeWhere((item) => item.id == doc.id));
                          if (mounted) setState(() => _message = 'Moved one duplicate to Recycle Bin. Remaining matches stay open.');
                        }
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'open', child: Text('Open PDF')),
                      PopupMenuItem(value: 'share', child: Text('Share PDF')),
                      PopupMenuItem(value: 'trash', child: Text('Move this copy to Recycle Bin')),
                    ],
                  ),
                );
              },
            )),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Back'))],
      ),
    ));
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _showDuplicates() async {
    final groups = await _tools.findDuplicateGroups();
    if (!mounted) return;
    await showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: const Text('Check Duplicate File'),
      content: SizedBox(width: 420, child: groups.isEmpty
        ? const Text('No duplicates found. Run OCR indexing first to detect matching scanned/text content.')
        : ListView(shrinkWrap: true, children: groups.map((g) => ListTile(
            leading: Icon(g['duplicate_type'] == 'SHA-256' ? Icons.fingerprint : Icons.text_snippet_outlined),
            title: Text('${g['copies']} matching PDF files · ${g['duplicate_type']}'),
            subtitle: Text((g['names'] ?? '').toString()),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.pop(context);
              final ids = (g['document_ids'] ?? '').toString().split(',').where((id) => id.isNotEmpty).toList();
              _reviewDuplicateGroup(ids, g['duplicate_type'] as String);
            },
          )).toList())),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    ));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_refreshDatabaseStatus());
    if (!_awaitingAllFilesPermission) return;
    _awaitingAllFilesPermission = false;
    unawaited(() async {
      try {
        if (await StorageLocationService.instance.hasAllFilesAccess() && mounted) {
          final source = _resumeRecoverySource;
          _resumeRecoverySource = null;
          await _restorePortableSnapshot(autoDetect: _resumeAutoDetect,
              selectedSource: source);
        } else if (mounted) {
          setState(() => _message = 'Storage access was not granted. '
              'Your existing PDFs are unchanged. Open Emergency Recovery to retry.');
        }
      } catch (error) {
        if (mounted) setState(() => _message = 'Could not verify storage permission: $error');
      }
    }());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Invalidate pending search completions before the route is deactivated.
    _searchGeneration++;
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Capture actions must not flash the generic tools catalogue.
    if (widget.quickAction == 'camera' || widget.quickAction == 'gallery') {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(widget.quickAction == 'camera' ? 'Opening camera…' : 'Opening photo gallery…'),
        ]),
      );
    }
    return ListView(
    padding: const EdgeInsets.all(16),
    children: [
      if (_busy) LinearProgressIndicator(value: _backupProgress),
      if (_message != null) Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(_message!, style: Theme.of(context).textTheme.bodyMedium),
      ),
      if (widget.section == 'tools') ...[
        Card(child: Column(children: [
          ListTile(leading: const Icon(Icons.text_snippet_outlined),
            title: const Text('OCR Search Inside PDF'),
            trailing: IconButton(tooltip: 'Start indexing', onPressed: _busy ? null : _indexDocuments,
              icon: const Icon(Icons.play_arrow))),
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: Column(children: [
            TextField(controller: _search, decoration: InputDecoration(
              labelText: 'Search text inside indexed PDFs',
              suffixIcon: IconButton(
                key: const ValueKey('ocr-search-button'),
                onPressed: _searching ? null : _searchText,
                icon: _searching
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.search))),
              onSubmitted: (_) => _searchText()),
            const SizedBox(height: 6),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'OCR languages: Android supports English and Hindi. iPhone currently supports Latin-script text only.',
                style: TextStyle(fontSize: 12),
              ),
            ),
            if (_results.isNotEmpty) ...[
              const SizedBox(height: 8),
              ..._results.map((r) => ListTile(dense: true,
                leading: const Icon(Icons.picture_as_pdf_outlined),
                title: Text((r['name'] ?? '').toString()),
                subtitle: Text('Found on page ${r['match_page'] ?? 1} · Tap to open PDF'),
                trailing: IconButton(tooltip: 'Open PDF', icon: const Icon(Icons.open_in_new), onPressed: () => _openSearchResult(r)),
                onTap: () => _openSearchResult(r))),
            ] else if (_hasSearched && _search.text.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              const Align(alignment: Alignment.centerLeft,
                child: Text('No match found in indexed PDFs.')),
            ],
          ])),
          const Divider(height: 1),
          ListTile(leading: const Icon(Icons.copy_all_outlined),
            title: const Text('Duplicate review'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _showDuplicates),
        ])),
      ],
      if (widget.section == 'backup' || widget.section == 'restore' ||
          widget.section == 'backup_restore') ...[
        Card(child: Column(children: [
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: const Text('Full Backup'),
            subtitle: Text(_backupUsageReady
                ? 'Storage used: ' + _formatSize(
                      _manualBackupSets.fold<int>(0, (n, e) => n + e.bytes)) +
                    ' · ' + _manualBackupSets.fold<int>(
                      0, (n, e) => n + e.files).toString() + ' ZIP files'
                : 'Backup storage: checking availability…'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Wrap(spacing: 8, runSpacing: 4, children: [
              FilledButton.icon(onPressed: _busy ? null : _backup,
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('Create Backup')),
              OutlinedButton.icon(onPressed: _busy ? null : _showCleanBackups,
                icon: const Icon(Icons.delete_outline), label: const Text('Clean')),
              TextButton.icon(onPressed: _busy ? null : _showExportBackups,
                icon: const Icon(Icons.ios_share_outlined), label: const Text('Export')),
            ]),
          ),
          const Divider(height: 1),
          const ListTile(leading: Icon(Icons.info_outline),
            subtitle: Text('For transferring your library to another phone.')),
        ])),
        const SizedBox(height: 8),
        Card(child: Column(children: [
          ListTile(leading: const Icon(Icons.storage_outlined),
            title: const Text('Database Backup'),
            subtitle: Text(
              (Platform.isAndroid || widget.forceAndroidBackupForTesting
                ? 'Automatic • Every 24 hours' : 'Manual database backup') +
              '\nLast successful backup: ' + (_lastDatabaseBackup == null ? '—'
                : MaterialLocalizations.of(context).formatShortDate(_lastDatabaseBackup!) +
                  ' ' + MaterialLocalizations.of(context).formatTimeOfDay(
                    TimeOfDay.fromDateTime(_lastDatabaseBackup!))))),
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Align(alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(onPressed: _busy ? null : _databaseBackup,
                icon: const Icon(Icons.play_arrow), label: const Text('Backup Now')))),
        ])),
        const SizedBox(height: 8),
        Card(child: ListTile(
          leading: const Icon(Icons.settings_backup_restore_outlined),
          title: const Text('Restore Backup'),
          subtitle: const Text('Restore from a Full or Database ZIP.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : () => _restoreBackup(),
        )),
        if (Platform.isAndroid || widget.forceAndroidBackupForTesting) ...[
          const SizedBox(height: 8),
          Card(child: ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('Emergency Recovery'),
            subtitle: const Text('Recover existing folders and PDFs.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _showEmergencyRecovery,
          )),
        ],
      ],
    ],
  );
  }
}
