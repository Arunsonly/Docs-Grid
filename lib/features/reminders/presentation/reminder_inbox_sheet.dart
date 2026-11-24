import 'package:flutter/material.dart';

import '../data/reminder_notifications.dart';
import '../data/reminder_repository.dart';

/// Read-only, on-device access to saved reminders. This is deliberately not
/// an OS-delivery log: Android does not guarantee a delivered-notification
/// history to apps. Tapping an attached reminder opens its PDF.
class ReminderInboxSheet extends StatefulWidget {
  const ReminderInboxSheet({
    super.key,
    required this.reminders,
    required this.onOpenDocument,
    required this.onOpenAll,
  });

  final Future<List<ReminderRecord>> reminders;
  final ValueChanged<String> onOpenDocument;
  final VoidCallback onOpenAll;

  static int dueCount(List<ReminderRecord> items, DateTime now) {
    return items.where((item) => item.enabled &&
        item.status != 'completed' && item.status != 'cancelled' &&
        item.recurrenceRule == null && !item.remindAt.isAfter(now)).length;
  }

  static bool isActive(ReminderRecord item) =>
      item.enabled && item.status != 'completed' &&
      item.status != 'cancelled';

  @override
  State<ReminderInboxSheet> createState() => _ReminderInboxSheetState();
}

class _ReminderInboxSheetState extends State<ReminderInboxSheet> {
  String _dateLabel(DateTime date) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(date.day)}/${two(date.month)}/${date.year} · '
        '${two(date.hour)}:${two(date.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FractionallySizedBox(
        heightFactor: 0.76,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 12, 4),
            child: Row(children: [
              const Icon(Icons.notifications_outlined),
              const SizedBox(width: 10),
              const Expanded(child: Text('Document reminders',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
              IconButton(
                tooltip: 'Close reminders',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ]),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 0, 18, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Saved reminders, including due and upcoming alerts. '
                'This is not a record of notifications delivered by Android.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<ReminderRecord>>(
              future: widget.reminders,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return const Center(child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('Could not read saved reminders. Try again from Reminders.'),
                  ));
                }
                final now = DateTime.now();
                final items = (snapshot.data ?? const <ReminderRecord>[])
                    .where(ReminderInboxSheet.isActive)
                    .toList(growable: false);
                items.sort((a, b) {
                  final aDue = a.recurrenceRule == null && !a.remindAt.isAfter(now);
                  final bDue = b.recurrenceRule == null && !b.remindAt.isAfter(now);
                  if (aDue != bDue) return aDue ? -1 : 1;
                  return a.remindAt.compareTo(b.remindAt);
                });
                if (items.isEmpty) {
                  return const Center(child: Text('No active reminders.'));
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final due = item.recurrenceRule == null &&
                        !item.remindAt.isAfter(now);
                    final scheduled = item.recurrenceRule == null
                        ? item.remindAt
                        : ReminderNotifications.nextScheduledOccurrence(
                            at: item.remindAt, now: now,
                            recurrence: item.recurrenceRule) ?? item.remindAt;
                    return ListTile(
                      key: ValueKey('reminder-inbox-${item.id}'),
                      leading: Icon(due
                          ? Icons.notification_important_outlined
                          : Icons.notifications_none_outlined),
                      title: Text(item.title,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text([
                        if (item.documentName != null)
                          'PDF: ${item.documentName}.pdf',
                        if (item.note?.isNotEmpty == true) item.note!,
                        '${due ? 'Due' : 'Scheduled'} · ${_dateLabel(scheduled)}',
                      ].join('\n'), maxLines: 4),
                      trailing: Icon(item.documentId == null
                          ? Icons.chevron_right : Icons.picture_as_pdf_outlined),
                      onTap: () {
                        Navigator.of(context).pop();
                        final documentId = item.documentId;
                        if (documentId == null || documentId.isEmpty) {
                          widget.onOpenAll();
                        } else {
                          widget.onOpenDocument(documentId);
                        }
                      },
                    );
                  },
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: TextButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                widget.onOpenAll();
              },
              icon: const Icon(Icons.alarm_outlined),
              label: const Text('Manage all reminders'),
            ),
          ),
        ]),
      ),
    );
  }
}
