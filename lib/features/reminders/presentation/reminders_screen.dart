import 'package:flutter/material.dart';
import '../data/reminder_repository.dart';
import '../data/reminder_notifications.dart';

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

  Future<void> _requestNotificationPermission() async {
    try {
      await ReminderNotifications.instance.requestPermission();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification permission request completed. Check Android notification settings if reminders remain silent.')),
      );
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not request notification permission: $error')));
    }
  }

  Future<void> _add({ReminderRecord? existing}) async {
    final title = TextEditingController(text: existing?.title ?? '');
    final note = TextEditingController(text: existing?.note ?? '');
    DateTime selected = existing?.remindAt ?? DateTime.now().add(const Duration(hours: 1));
    String recurrence = existing?.recurrenceRule ?? 'none';
    final result = await showDialog<bool>(context: context, builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(existing == null ? 'New reminder' : 'Edit reminder'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, autofocus: true, decoration: const InputDecoration(labelText: 'Reminder title')),
          TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'Note (optional)')),
          DropdownButtonFormField<String>(
            initialValue: recurrence,
            decoration: const InputDecoration(labelText: 'Repeat'),
            items: const [
              DropdownMenuItem(value: 'none', child: Text('Does not repeat')),
              DropdownMenuItem(value: 'daily', child: Text('Daily')),
              DropdownMenuItem(value: 'weekly', child: Text('Weekly')),
            ],
            onChanged: (value) => setDialogState(() => recurrence = value ?? 'none'),
          ),
          const SizedBox(height: 8),
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
          FilledButton(onPressed: () { if (title.text.trim().isNotEmpty && selected.isAfter(DateTime.now())) Navigator.pop(dialogContext, true); }, child: Text(existing == null ? 'Save' : 'Update'))],
      ),
    ));
    if (result == true) {
      if (existing == null) {
        await _repository.create(title: title.text, note: note.text, remindAt: selected, recurrenceRule: recurrence == 'none' ? null : recurrence);
      } else {
        await _repository.update(id: existing.id, title: title.text, note: note.text, remindAt: selected, recurrenceRule: recurrence == 'none' ? null : recurrence);
      }
      await _refresh();
    }
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
    body: Column(children: [
      Card(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('How to set a notification', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('1. Tap Add reminder.  2. Enter a title.  3. Choose date and time.  4. Select repeat (optional).  5. Tap Save. Keep the reminder Enabled.'),
            Align(alignment: Alignment.centerRight, child: TextButton.icon(
              onPressed: _requestNotificationPermission,
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Allow notifications'),
            )),
          ]),
        ),
      ),
      Expanded(child: FutureBuilder<List<ReminderRecord>>(future: _future, builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
      if (snapshot.hasError) return Center(child: Text('Could not load reminders: ${snapshot.error}'));
      final items = snapshot.data ?? [];
      if (items.isEmpty) return const Center(child: Text('No reminders yet. Add a reminder for a date and time.'));
      return RefreshIndicator(onRefresh: _refresh, child: ListView.separated(padding: const EdgeInsets.fromLTRB(12, 8, 12, 100), itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 6), itemBuilder: (context, index) {
          final item = items[index]; final date = item.remindAt;
          final label = '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year} · ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
          return Card(elevation: 0, child: ListTile(leading: CircleAvatar(child: Icon(item.status == 'completed' ? Icons.check : Icons.alarm)),
            title: Text(item.title), subtitle: Text([if (item.note?.isNotEmpty == true) item.note!, if (item.recurrenceRule != null) 'Repeats ${item.recurrenceRule}', label, if (item.status == 'completed') 'Completed', if (item.enabled && date.isBefore(DateTime.now()) && item.status != 'completed') 'Past due'].join('\n')),
            trailing: PopupMenuButton<String>(onSelected: (value) async {
              if (value == 'toggle') await _repository.setEnabled(item, !item.enabled);
              if (value == 'complete') await _repository.complete(item.id);
              if (value == 'snooze') await _repository.snooze(item);
              if (value == 'duplicate') await _repository.duplicate(item);
              if (value == 'edit') { await _add(existing: item); return; }
              if (value == 'delete') await _delete(item);
              await _refresh();
            }, itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'toggle', child: Text(item.enabled ? 'Disable' : 'Enable')),
              if (item.status != 'completed') const PopupMenuItem(value: 'complete', child: Text('Mark completed')),
              if (item.status != 'completed') const PopupMenuItem(value: 'snooze', child: Text('Snooze 1 day')),
              const PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
              const PopupMenuItem(value: 'delete', child: Text('Delete'))]),
          ));
        }));
    })),
    ]),
  );
}
