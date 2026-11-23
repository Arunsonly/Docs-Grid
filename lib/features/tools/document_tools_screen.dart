import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/database/app_database.dart';
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
  List<BackupChainUsage> _manualBackupSets = const [];
  bool _backupUsageReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tools = widget.service ?? DocumentToolsService();
    if (widget.section == 'backup' || widget.section == 'restore' ||
        widget.section == 'backup_restore') {
      unawaited(_refreshBackupUsage());
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
    setState(() { _busy = true; _message = null; });
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
      if (mounted) setState(() => _busy = false);
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

  Future<void> _backup() => _run(() async {
    // Keep the pre-existing iOS standalone Full Backup behaviour intact.
    // A-series incremental storage currently targets Android's file root.
    if (!Platform.isAndroid && !widget.forceAndroidBackupForTesting) {
      final archive = await _tools.createBackup(includePdfs: true);
      await _tools.shareFile(archive.path, text: 'DocsGrid Full backup');
      if (mounted) setState(() => _message =
          'Full backup verified. Save the shared archive somewhere safe.');
      return;
    }
    if (mounted) setState(() => _message = 'Checking existing backup series…');
    final sets = await _tools.manualBackupUsage()
        .timeout(const Duration(seconds: 20));
    var newFull = false;
    final series = sets.where((s) => s.name.startsWith('A') &&
        !s.name.endsWith('.zip')).toList();
    if (series.isNotEmpty) {
      if (!mounted) return;
      final choice = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Create PDF backup'),
          content: const Text('Continue the latest A-series using only new '
              'or changed PDFs, or start a new independent Full series?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, true),
                child: const Text('New Full')),
            FilledButton(onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Incremental')),
          ],
        ),
      );
      if (choice == null) return;
      newFull = choice;
    }
    if (mounted) setState(() => _message = 'Preparing verified PDF backup…');
    final archive = await _tools.createManualBackup(
      newFull: newFull,
      onStage: (stage) {
        if (mounted) setState(() => _message = stage);
      },
      onProgress: (completed, total) {
        if (!mounted) return;
        setState(() => _message = total == 0
            ? 'Preparing backup…'
            : 'Checking PDFs: $completed of $total');
      },
    );
    // The validated archive has already completed. Refreshing the optional
    // storage-usage counter must NOT keep the UI waiting or suppress success.
    if (mounted) setState(() => _message =
        'Verified backup created: ' + p.basename(archive.parent.path) +
        '/' + p.basename(archive.path) +
        '. Keep the complete A-series together when exporting.');
    unawaited(_refreshBackupUsage());
  });

  Future<void> _exportBackupSeries(String id) => _run(() async {
    final selected = await StorageLocationService.instance
        .chooseBackupExportFolder();
    if (selected == null) return;
    if (mounted) setState(() => _message =
        'Exporting verified ' + id + ' backup to external storage…');
    final bytes = await _tools.exportManualBackupSeries(
        id, selected['uri']!);
    if (mounted) setState(() => _message =
        'Exported ' + id + ' successfully (' + _formatSize(bytes) +
        '). The original backup remains unchanged.');
  });

  Future<void> _cleanBackupSeries(String id) async {
    final usage = _manualBackupSets.where((item) => item.name == id);
    if (usage.isEmpty || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete backup ' + id + '?'),
        content: Text('This permanently removes the selected backup. '
            'For A-series, every dependent Incremental ZIP is included.\n\n'
            'Storage to free: ' + _formatSize(usage.single.bytes) +
            '.\n\nYour original PDFs in My Files will NOT be touched. '
            'Deleted backups cannot be restored from this location.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete series')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() async {
      await _tools.deleteManualBackupSeries(id);
      await _refreshBackupUsage();
      if (mounted) setState(() => _message =
          'Backup series ' + id + ' deleted. My Files was not changed.');
    });
  }

  Future<void> _showCleanBackups() async {
    await _refreshBackupUsage();
    if (!mounted) return;
    final series = _manualBackupSets;
    await showModalBottomSheet<void>(
      context: context, isScrollControlled: true,
      builder: (ctx) => SafeArea(child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const ListTile(title: Text('Clean Backups'),
              subtitle: Text('Delete an entire series safely; parents are never left orphaned.')),
          if (series.isEmpty)
            const ListTile(title: Text('No manual backups to clean')),
          ...series.map((item) => ListTile(
            leading: const Icon(Icons.folder_zip_outlined),
            title: Text(item.name),
            subtitle: Text(_formatSize(item.bytes) +
                ' · ' + item.files.toString() + ' ZIP files'),
            trailing: const Icon(Icons.delete_outline),
            onTap: () {
              Navigator.pop(ctx);
              unawaited(_cleanBackupSeries(item.name));
            },
          )),
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Close')),
        ]),
      )),
    );
  }

  Future<void> _showExportBackups() async {
    await _refreshBackupUsage();
    if (!mounted) return;
    final series = _manualBackupSets;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: Text('Export a backup series'),
            subtitle: Text('Keep all Parent and Incremental ZIPs together.')),
          ...series.map((item) => ListTile(
            leading: const Icon(Icons.ios_share_outlined),
            title: Text(item.name),
            subtitle: Text(_formatSize(item.bytes)),
            onTap: () {
              Navigator.pop(ctx);
              unawaited(_exportBackupSeries(item.name));
            },
          )),
          if (series.isEmpty)
            const ListTile(title: Text('No manual backups available')),
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Close')),
        ],
      )),
    );
  }

  Future<void> _databaseBackup() => _run(() async {
    final archive = await _tools.createBackup(includePdfs: false);
    await _tools.shareFile(archive.path, text: 'DocsGrid database backup');
    if (mounted) {
      setState(() => _message =
          'Database backup created. It contains metadata only; PDF contents are not included.');
    }
  });

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

  Future<void> _restoreBackup() => _run(() async {
    final source = await showModalBottomSheet<String>(
      context: context, showDragHandle: true,
      builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const ListTile(title: Text('Choose restore source')),
        ListTile(leading: const Icon(Icons.archive_outlined), title: const Text('Backup ZIP file'),
          subtitle: const Text('Standalone Full or Database ZIP.'),
          onTap: () => Navigator.pop(ctx, 'zip')),
        if (Platform.isAndroid)
          ListTile(leading: const Icon(Icons.folder_zip_outlined), title: const Text('Incremental series folder'),
          subtitle: const Text('Select an A001 folder containing its parent and I-series ZIP files.'),
          onTap: () => Navigator.pop(ctx, 'series')),
        if (Platform.isAndroid)
          ListTile(leading: const Icon(Icons.picture_as_pdf_outlined), title: const Text('PDF folder'),
          subtitle: const Text('Find PDFs in any readable folder without moving originals.'),
          onTap: () => Navigator.pop(ctx, 'pdf_folder')),
      ])),
    );
    if (source == 'pdf_folder') {
      await _recoverSelectedPdfFolder();
      return;
    }
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
    if (autoDetect) {
      // Find the existing Android/media/DocsGrid tree automatically. Android
      // requires its special all-files access switch for this personal-use build.
      if (Platform.isAndroid && !await storage.hasAllFilesAccess()) {
        _awaitingAllFilesPermission = true;
        await storage.requestAllFilesAccess();
        if (mounted) {
          setState(() => _message =
              'Allow Full internal storage access for DocsGrid. Recovery will scan automatically when you return.');
        }
        return;
      }
      await storage.portableDataLocations();
      final portableBackups = await _tools.listPortableBackupArchives();
      if (portableBackups.isNotEmpty) {
        await _restoreNewestPortableBackupBody();
        return;
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
              'choose Restore backup → Incremental series folder, then select '
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
    if (snapshot == null) {
      if (!Platform.isAndroid) {
        throw StateError('No verified DocsGrid snapshot was found in the selected folder.');
      }
      final recovered = await _tools.recoverLoosePortablePdfs(
        additionalFolderUri: recoverySource?['libraryUri'],
        additionalDocumentsUri: recoverySource?['documentsUri'],
        onProgress: (completed, total) {
          if (mounted) setState(() => _message = 'Recovering PDFs: $completed of $total');
        },
      );
      await _showRecoveryResult(RecoveryResultData.fromPdfFolder(
        recovered,
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
    final result = await _tools.restoreLatestPortableMetadataSnapshot(
      sourceLocations: recoverySource,
      onProgress: (completed, total) {
        if (mounted) {
          setState(() => _message = 'Matching snapshot PDFs: $completed of $total');
        }
      },
    );

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
    if (state != AppLifecycleState.resumed || !_awaitingAllFilesPermission) return;
    _awaitingAllFilesPermission = false;
    unawaited(() async {
      try {
        if (await StorageLocationService.instance.hasAllFilesAccess() && mounted) {
          await _restorePortableSnapshot(autoDetect: true);
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
      if (_busy) const LinearProgressIndicator(),
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
      if (widget.section == 'backup' || widget.section == 'restore' || widget.section == 'backup_restore') Card(child: Column(children: [
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
              icon: const Icon(Icons.delete_outline),
              label: const Text('Clean')),
            TextButton.icon(onPressed: _busy ? null : _showExportBackups,
              icon: const Icon(Icons.ios_share_outlined),
              label: const Text('Export')),
          ]),
        ),
        const Divider(height: 1),
        ListTile(leading: const Icon(Icons.storage_outlined), title: const Text('Create database backup'),
          subtitle: const Text('Save database and metadata only; PDF contents are excluded.'),
          trailing: const Icon(Icons.chevron_right), onTap: _busy ? null : _databaseBackup),
        const Divider(height: 1),
        ListTile(leading: const Icon(Icons.settings_backup_restore_outlined), title: const Text('Restore backup'),
          subtitle: const Text('Choose a DocsGrid backup ZIP from this phone or another storage location.'),
          trailing: const Icon(Icons.chevron_right), onTap: _busy ? null : _restoreBackup),
      ])),
    ],
  );
  }
}
