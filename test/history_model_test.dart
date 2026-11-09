import 'package:docs_grid/features/history/data/history_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Activity record remains readable when optional details JSON is malformed', () {
    final record = ActivityRecord.fromMap({
      'id': 'history-1',
      'action': 'opened',
      'document_name': 'Policy',
      'created_at': '2026-11-08T10:00:00.000Z',
      'details_json': '{broken',
    });

    expect(record.action, 'opened');
    expect(record.documentName, 'Policy');
    expect(record.details, isEmpty);
  });
  test('Activity record remains readable when timestamp and name metadata are malformed', () {
    final record = ActivityRecord.fromMap({
      'id': 'history-2',
      'action': 'category_created',
      'document_name': 42,
      'created_at': 'not-a-date',
      'details_json': '{"name":"Insurance"}',
    });

    expect(record.action, 'category_created');
    expect(record.documentName, isNull);
    expect(record.details['name'], 'Insurance');
    expect(record.createdAt, DateTime.fromMillisecondsSinceEpoch(0).toLocal());
  });
}
