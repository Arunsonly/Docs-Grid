import 'package:flutter/material.dart';

/// Presentation-only results. These numbers describe completed operations;
/// this file must not read or modify PDFs, SQLite, backups, or storage grants.
enum RecoveryResultKind { recovered, upToDate, partial, failed, noPdfs }

class RecoveryResultMetric {
  const RecoveryResultMetric(this.label, this.value);
  final String label;
  final int value;
}

class RecoveryResultData {
  const RecoveryResultData({
    required this.kind,
    required this.subtitle,
    required this.metrics,
    required this.details,
    this.sourceFilesRetained = true,
  });

  final RecoveryResultKind kind;
  final String subtitle;
  final List<RecoveryResultMetric> metrics;
  final String details;
  final bool sourceFilesRetained;

  String get title => switch (kind) {
    RecoveryResultKind.recovered => 'Recovery completed',
    RecoveryResultKind.upToDate => 'Already up to date',
    RecoveryResultKind.partial => 'Recovery partially completed',
    RecoveryResultKind.failed => 'Recovery failed',
    RecoveryResultKind.noPdfs => 'No PDFs found',
  };

  IconData get icon => switch (kind) {
    RecoveryResultKind.recovered || RecoveryResultKind.upToDate =>
      Icons.check_circle_outline,
    RecoveryResultKind.partial => Icons.warning_amber_rounded,
    RecoveryResultKind.failed => Icons.error_outline,
    RecoveryResultKind.noPdfs => Icons.info_outline,
  };

  static int _count(Map<String, int> values, String key) =>
      (values[key] ?? 0).clamp(0, 0x7fffffff);

  /// 'added' includes relinked records in the existing recovery service.
  /// Do not present a relinked PDF as newly imported.
  factory RecoveryResultData.fromPdfFolder(
    Map<String, int> result, {
    String? failureReasons,
    String? note,
  }) {
    final added = _count(result, 'added');
    final relinked = _count(result, 'relinked');
    final newPdfs = (added - relinked).clamp(0, added);
    final duplicates = _count(result, 'duplicates');
    final failed = _count(result, 'failed');
    final folders = _count(result, 'folders');
    final successful = added > 0 || folders > 0 || duplicates > 0;
    final kind = failed > 0
        ? (successful ? RecoveryResultKind.partial : RecoveryResultKind.failed)
        : added > 0 || folders > 0
            ? RecoveryResultKind.recovered
            : duplicates > 0
                ? RecoveryResultKind.upToDate
                : RecoveryResultKind.noPdfs;
    final subtitle = switch (kind) {
      RecoveryResultKind.recovered =>
        'Available PDFs were added or reconnected to DocsGrid.',
      RecoveryResultKind.upToDate =>
        'No new PDFs were needed. Existing records were retained.',
      RecoveryResultKind.partial =>
        'Some files were processed, but others need attention.',
      RecoveryResultKind.failed =>
        'No PDF could be recovered. Check the failure details.',
      RecoveryResultKind.noPdfs =>
        'No readable PDFs were registered from the selected source.',
    };
    return RecoveryResultData(
      kind: kind,
      subtitle: subtitle,
      metrics: [
        RecoveryResultMetric('New PDFs', newPdfs),
        RecoveryResultMetric('Relinked PDFs', relinked),
        RecoveryResultMetric('Already registered', duplicates),
        RecoveryResultMetric('Failed PDFs', failed),
      ],
      details:
          'PDF scan: new $newPdfs; relinked $relinked; already registered '
          '$duplicates; failed $failed; new folders $folders.\n'
          'Original source PDFs were not deleted or overwritten.'
          '${failureReasons == null || failureReasons.isEmpty ? '' : '\nFailure reasons: $failureReasons'}'
          '${note == null || note.isEmpty ? '' : '\n$note'}',
    );
  }

  /// Folder/category/tag counts describe records IN the verified snapshot,
  /// not necessarily new items inserted into the current database.
  factory RecoveryResultData.fromSnapshot(
    Map<String, int> snapshot,
    Map<String, int> scan, {
    String? scanWarning,
  }) {
    final documentsAdded = _count(snapshot, 'documentsAdded');
    final linked = _count(snapshot, 'documentsLinked');
    final initiallyUnmatched = _count(snapshot, 'pdfsMissing');
    final additional = _count(scan, 'added');
    final extraRelinked = _count(scan, 'relinked');
    final extraNew = (additional - extraRelinked).clamp(0, additional);
    final duplicates = _count(scan, 'duplicates');
    final failed = _count(scan, 'failed');
    final folders = _count(snapshot, 'folders');
    final extraFolders = _count(scan, 'folders');
    final hadChanges = documentsAdded > 0 || linked > 0 || additional > 0 ||
        extraFolders > 0;
    final hasMetadata = folders > 0 ||
        _count(snapshot, 'categories') > 0 ||
        _count(snapshot, 'tags') > 0 ||
        _count(snapshot, 'reminders') > 0 ||
        _count(snapshot, 'settings') > 0 ||
        _count(snapshot, 'activity') > 0;
    final hadErrors = failed > 0 || (scanWarning?.isNotEmpty ?? false);
    final kind = hadErrors
        ? (hadChanges || duplicates > 0 || hasMetadata
            ? RecoveryResultKind.partial
            : RecoveryResultKind.failed)
        : hadChanges
            ? RecoveryResultKind.recovered
            : duplicates > 0
                ? RecoveryResultKind.upToDate
                : hasMetadata
                    ? RecoveryResultKind.recovered
                    : RecoveryResultKind.noPdfs;
    return RecoveryResultData(
      kind: kind,
      subtitle: switch (kind) {
        RecoveryResultKind.recovered =>
          'Verified snapshot metadata and available PDFs were processed.',
        RecoveryResultKind.upToDate =>
          'No additional PDFs were found. Snapshot metadata was checked.',
        RecoveryResultKind.partial =>
          'Snapshot recovery finished, but part of the PDF scan needs attention.',
        RecoveryResultKind.failed =>
          'Recovery could not register the available PDFs.',
        RecoveryResultKind.noPdfs =>
          'No snapshot PDF records or available PDFs were recovered.',
      },
      metrics: [
        RecoveryResultMetric('Document records added', documentsAdded),
        RecoveryResultMetric('PDFs linked', linked + extraRelinked),
        RecoveryResultMetric('New PDFs in extra scan', extraNew),
        RecoveryResultMetric('Already registered', duplicates),
        RecoveryResultMetric('Failed PDFs', failed),
        RecoveryResultMetric('Folder records in snapshot', folders),
      ],
      details:
          'Verified snapshot — folder records: $folders; document records '
          'added: $documentsAdded; PDF records linked: $linked; '
          'initially unmatched: $initiallyUnmatched.\n'
          'Additional PDF scan — newly registered: $extraNew; relinked: '
          '$extraRelinked; already registered: $duplicates; failed: $failed; '
          'new folders: $extraFolders.\n'
          'Snapshot record counts (not necessarily newly created) — '
          'categories: ${_count(snapshot, 'categories')}; '
          'tags: ${_count(snapshot, 'tags')}; '
          'PDF-tag links: ${_count(snapshot, 'documentTags')}; '
          'reminders: ${_count(snapshot, 'reminders')}; '
          'history: ${_count(snapshot, 'activity')}; '
          'OCR indexes: ${_count(snapshot, 'ocrIndexes')}; '
          'settings: ${_count(snapshot, 'settings')}.\n'
          'Initial unmatched count is not the final missing-PDF count. '
          'Reminder notifications are scheduled separately.\n'
          'Original source PDFs were not deleted or overwritten.'
          '${scanWarning == null || scanWarning.isEmpty ? '' : '\nPDF scan warning: $scanWarning'}',
    );
  }

  factory RecoveryResultData.fromArchive(
    int payloads, {
    Map<String, int>? scanned,
    String? scanWarning,
  }) {
    final restored = payloads < 0 ? 0 : payloads;
    final relinked = _count(scanned ?? const {}, 'relinked');
    final imported = (_count(scanned ?? const {}, 'added') - relinked)
        .clamp(0, 0x7fffffff);
    final duplicates = _count(scanned ?? const {}, 'duplicates');
    final failed = _count(scanned ?? const {}, 'failed');
    final hasProblems = failed > 0 || (scanWarning?.isNotEmpty ?? false);
    final kind = hasProblems
        ? (restored > 0 || relinked > 0 || imported > 0
            ? RecoveryResultKind.partial
            : RecoveryResultKind.partial) // Database metadata may have restored.
        : restored > 0 || relinked > 0 || imported > 0
            ? RecoveryResultKind.recovered
            : RecoveryResultKind.upToDate; // Database-only restore can be valid.
    return RecoveryResultData(
      kind: kind,
      subtitle: hasProblems
          ? 'Backup restore finished, but checking surviving PDFs needs attention.'
          : restored == 0
              ? 'Database restore completed. No PDF payloads needed copying.'
              : 'Verified PDF payloads were restored from the backup.',
      metrics: [
        RecoveryResultMetric('Verified PDF payloads', restored),
        RecoveryResultMetric('Relinked PDFs', relinked),
        RecoveryResultMetric('New PDFs from scan', imported),
        RecoveryResultMetric('Failed PDFs', failed),
      ],
      details:
          'Backup restore — verified PDF payloads: $restored; '
          'relinked surviving PDFs: $relinked; additional PDFs: $imported; '
          'already registered in scan: $duplicates; scan failures: $failed.\n'
          'A result of zero PDF payloads does not mean database restore failed.'
          '${scanWarning == null || scanWarning.isEmpty ? '' : '\nPDF scan warning: $scanWarning'}',
    );
  }

  factory RecoveryResultData.failure(Object error) => RecoveryResultData(
    kind: RecoveryResultKind.failed,
    subtitle: 'Recovery could not be completed. Your existing files were not intentionally deleted.',
    metrics: const [],
    details: 'Error: $error\nSee local error logs for diagnostics.',
  );
}

/// A single compact, expandable result dialog. It only displays results;
/// it does not execute a second recovery or change any stored data.
Future<void> showRecoveryResultDialog(
  BuildContext context,
  RecoveryResultData result,
) async {
  var expanded = false;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: Row(
          children: [
            Icon(result.icon, color: result.kind == RecoveryResultKind.failed
                ? Theme.of(dialogContext).colorScheme.error
                : Theme.of(dialogContext).colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(result.title, style:
                Theme.of(dialogContext).textTheme.titleLarge)),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(result.subtitle),
                if (result.metrics.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  for (final metric in result.metrics)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(children: [
                        Expanded(child: Text(metric.label)),
                        Text('${metric.value}',
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                      ]),
                    ),
                ],
                const SizedBox(height: 12),
                if (result.sourceFilesRetained)
                  const Row(children: [
                    Icon(Icons.shield_outlined, size: 19),
                    SizedBox(width: 7),
                    Expanded(child: Text('Original source PDFs were kept.',
                        style: TextStyle(fontSize: 13))),
                  ]),
                TextButton.icon(
                  onPressed: () => setDialogState(() => expanded = !expanded),
                  icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
                  label: Text(expanded ? 'Hide details' : 'View details'),
                ),
                if (expanded)
                  SelectableText(result.details, key: const ValueKey('recovery-result-details')),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    ),
  );
}
