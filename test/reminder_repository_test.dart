import 'package:docs_grid/features/reminders/data/reminder_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ReminderRecord maps stored UTC values to local date time', () {
    final record = ReminderRecord.fromMap({
      'id': 'reminder-1',
      'title': 'Renew insurance',
      'note': 'Check policy',
      'remind_at_utc': '2026-12-01T10:30:00.000Z',
      'enabled': 1,
      'status': 'scheduled',
      'document_id': null,
      'document_name': null,
    });

    expect(record.id, 'reminder-1');
    expect(record.title, 'Renew insurance');
    expect(record.note, 'Check policy');
    expect(record.enabled, isTrue);
    expect(record.status, 'scheduled');
    expect(record.remindAt.isUtc, isFalse);
    expect(record.documentId, isNull);
  });

  test('ReminderRecord maps disabled and completed state', () {
    final record = ReminderRecord.fromMap({
      'id': 'reminder-2',
      'title': 'Call office',
      'note': null,
      'remind_at_utc': '2026-12-02T08:00:00.000Z',
      'enabled': 0,
      'status': 'completed',
      'document_id': 'doc-1',
      'document_name': 'Policy',
    });

    expect(record.enabled, isFalse);
    expect(record.status, 'completed');
    expect(record.documentId, 'doc-1');
    expect(record.documentName, 'Policy');
  });
}
