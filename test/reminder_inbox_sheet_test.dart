import 'package:docs_grid/features/reminders/data/reminder_repository.dart';
import 'package:docs_grid/features/reminders/presentation/reminder_inbox_sheet.dart';
import 'package:docs_grid/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ReminderRecord reminder({
  required String id,
  required String title,
  required DateTime at,
  String? documentId,
  String? documentName,
  String? recurrenceRule,
  DateTime? snoozedUntil,
  bool enabled = true,
  String status = 'scheduled',
}) => ReminderRecord(
  id: id,
  title: title,
  note: 'Review the document',
  remindAt: at,
  enabled: enabled,
  status: status,
  documentId: documentId,
  documentName: documentName,
  recurrenceRule: recurrenceRule,
  snoozedUntil: snoozedUntil,
);

void main() {
  test('badge counts due one-time reminders but not disabled/completed/upcoming',
      () {
    final now = DateTime(2026, 11, 24, 9);
    final items = [
      reminder(id: 'due', title: 'Policy due', at: now),
      reminder(id: 'next', title: 'Upcoming policy',
          at: now.add(const Duration(hours: 1))),
      reminder(id: 'disabled', title: 'Disabled', at: now,
          enabled: false),
      reminder(id: 'completed', title: 'Done', at: now,
          status: 'completed'),
      reminder(id: 'repeat', title: 'Recurring', at: now,
          recurrenceRule: 'daily'),
      reminder(id:'snoozed',title:'Snoozed',at:now,snoozedUntil:now.add(const Duration(hours:1))),
    ];
    expect(ReminderInboxSheet.dueCount(items, now), 1);
  });

  test('Phone and Grid Back navigate to Home without exiting app', () {
    expect(DocsGridHome.destinationAfterStorageBack(0), 1);
    expect(DocsGridHome.destinationAfterStorageBack(2), 1);
    expect(DocsGridHome.destinationAfterStorageBack(1), 1);
  });

  testWidgets('bell inbox opens associated PDF and has a manage fallback',
      (tester) async {
    var openedId = '';
    var openedReminders = false;
    final items = [
      reminder(
        id: 'policy',
        title: 'Renew policy',
        at: DateTime.now().add(const Duration(days: 1)),
        documentId: 'pdf-123',
        documentName: 'Policy 123',
      ),
      reminder(
        id: 'general',
        title: 'Call client',
        at: DateTime.now().add(const Duration(days: 2)),
      ),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (context) => ElevatedButton(
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => ReminderInboxSheet(
            reminders: Future.value(items),
            onOpenDocument: (id) => openedId = id,
            onOpenAll: () => openedReminders = true,
          ),
        ),
        child: const Text('Open bell'),
      ))),
    ));
    await tester.tap(find.text('Open bell'));
    await tester.pumpAndSettle();
    expect(find.text('Document reminders'), findsOneWidget);
    expect(find.text('Renew policy'), findsOneWidget);
    expect(find.textContaining('PDF: Policy 123.pdf'), findsOneWidget);
    await tester.tap(find.text('Renew policy'));
    await tester.pumpAndSettle();
    expect(openedId, 'pdf-123');

    await tester.tap(find.text('Open bell'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Call client'));
    await tester.pumpAndSettle();
    expect(openedReminders, isTrue);
  });
}
