import 'package:flutter/material.dart';

import '../data/history_repository.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _repository = HistoryRepository();
  late Future<List<ActivityRecord>> _future;

  @override
  void initState() {
    super.initState();
    _future = _repository.list();
  }

  Future<void> _refresh() async {
    final future = _repository.list();
    setState(() => _future = future);
    await future;
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear activity history?'),
        content: const Text('This removes activity records only. Your PDFs will not be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Clear history')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repository.clear();
    await _refresh();
  }

  String _label(ActivityRecord record) {
    switch (record.action) {
      case 'imported': return 'PDF imported';
      case 'opened': return 'PDF opened';
      case 'favorited': return 'Added to Saved';
      case 'unfavorited': return 'Removed from Saved';
      case 'restored': return 'Restored from Recycle Bin';
      case 'moved_to_recycle_bin': return 'Moved to Recycle Bin';
      case 'renamed': return 'PDF renamed';
      case 'permanently_deleted': return 'PDF permanently deleted';
      default: return record.action.replaceAll('_', ' ');
    }
  }

  IconData _icon(String action) {
    switch (action) {
      case 'imported': return Icons.file_download_outlined;
      case 'opened': return Icons.picture_as_pdf_outlined;
      case 'favorited': return Icons.star_outline;
      case 'unfavorited': return Icons.star_border;
      case 'restored': return Icons.restore;
      case 'moved_to_recycle_bin':
      case 'permanently_deleted': return Icons.delete_outline;
      case 'renamed': return Icons.drive_file_rename_outline;
      default: return Icons.history;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity history'),
        actions: [
          IconButton(
            tooltip: 'Clear history',
            onPressed: _clear,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: FutureBuilder<List<ActivityRecord>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Could not load history\n${snapshot.error}'));
          }
          final records = snapshot.data ?? [];
          if (records.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.history, size: 54),
                    SizedBox(height: 12),
                    Text('No activity yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                    SizedBox(height: 6),
                    Text('Your document actions will appear here.', textAlign: TextAlign.center),
                  ],
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              itemCount: records.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 64),
              itemBuilder: (context, index) {
                final record = records[index];
                final time = record.createdAt;
                final dateLabel = '${time.day.toString().padLeft(2, '0')}/${time.month.toString().padLeft(2, '0')}/${time.year} · ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
                return ListTile(
                  leading: CircleAvatar(child: Icon(_icon(record.action))),
                  title: Text(_label(record)),
                  subtitle: Text([
                    record.documentName ?? (record.details['name'] as String? ?? 'Document'),
                    dateLabel,
                  ].join('\n')),
                  isThreeLine: true,
                );
              },
            ),
          );
        },
      ),
    );
  }
}
