import 'package:flutter/material.dart';
import '../data/reminder_repository.dart';

class RemindersScreen extends StatefulWidget {
  const RemindersScreen({super.key});
  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> {
  final _repository = ReminderRepository();
  late Future<List<ReminderRecord>> _future;
  @override
  void initState() { super.initState(); _future = _repository.list(); }
  Future<void> _refresh() async { final next = _repository.list(); setState(() => _future = next); await next; }

  Future<void> _add() async {
    final title = TextEditingController();
    final note = TextEditingController();
    DateTime selected = DateTime.now().add(const Duration(hours: 1));
    final result = await showDialog<bool>(context: context, builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('New reminder'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, autofocus: true, decoration: const InputDecoration(labelText: 'Reminder title')),
          TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'Note (optional)')),
          ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.calendar_month_outlined),
            title: const Text('Date & time'),
            subtitle: Text('${selected.day.toString().padLeft(2, '0')}/${selected.month.toString().padLeft(2, '0')}/${selected.year} · ${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}'),
            onTap: () async {
              final date = await showDatePicker(context: context, initialDate: selected, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 3650)));
              if (date == null || !context.mounted) return;
              final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(selected));
              if (time != null) setDialogState(() => selected = DateTime(date.year, date.month, date.day, time.hour, time.minute));
            }),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () { if (title.text.trim().isNotEmpty && selected.isAfter(DateTime.now())) Navigator.pop(dialogContext, true); }, child: const Text('Save'))],
      ),
    ));
    if (result == true) { await _repository.create(title: title.text, note: note.text, remindAt: selected); await _refresh(); }
    title.dispose(); note.dispose();
  }

  Future<void> _delete(ReminderRecord item) async {
    final ok = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
      title: const Text('Delete reminder?'), content: Text('Delete “${item.title}”?'),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
        FilledButton.tonal(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete'))],
    ));
    if (ok == true) await _repository.delete(item.id);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Reminders')),
    floatingActionButton: FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add_alarm), label: const Text('Add reminder')),
    body: FutureBuilder<List<ReminderRecord>>(future: _future, builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
      if (snapshot.hasError) return Center(child: Text('Could not load reminders: ${snapshot.error}'));
      final items = snapshot.data ?? [];
      if (items.isEmpty) return const Center(child: Text('No reminders yet. Add a reminder for a date and time.'));
      return RefreshIndicator(onRefresh: _refresh, child: ListView.separated(padding: const EdgeInsets.fromLTRB(12, 8, 12, 100), itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 6), itemBuilder: (context, index) {
          final item = items[index]; final date = item.remindAt;
          final label = '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year} · ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
          return Card(elevation: 0, child: ListTile(leading: CircleAvatar(child: Icon(item.status == 'completed' ? Icons.check : Icons.alarm)),
            title: Text(item.title), subtitle: Text([if (item.note?.isNotEmpty == true) item.note!, label, if (item.status == 'completed') 'Completed', if (item.enabled && date.isBefore(DateTime.now()) && item.status != 'completed') 'Past due'].join('\n')),
            trailing: PopupMenuButton<String>(onSelected: (value) async {
              if (value == 'toggle') await _repository.setEnabled(item, !item.enabled);
              if (value == 'complete') await _repository.complete(item.id);
              if (value == 'delete') await _delete(item);
              await _refresh();
            }, itemBuilder: (_) => [PopupMenuItem(value: 'toggle', child: Text(item.enabled ? 'Disable' : 'Enable')),
              if (item.status != 'completed') const PopupMenuItem(value: 'complete', child: Text('Mark completed')),
              const PopupMenuItem(value: 'delete', child: Text('Delete'))]),
          ));
        }));
    }),
  );
}
