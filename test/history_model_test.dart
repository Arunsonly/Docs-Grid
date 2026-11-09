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
}
