import 'package:docs_grid/core/database/app_database.dart';
import 'package:docs_grid/features/reminders/data/reminder_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('creating a reminder persists a durable SQLite record', () async {
    sqfliteFfiInit();
    final database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.execute('''
      CREATE TABLE reminders (
        id TEXT PRIMARY KEY,
        document_id TEXT,
        title TEXT NOT NULL,
        note TEXT,
        remind_at_utc TEXT NOT NULL,
        timezone_id TEXT NOT NULL,
        recurrence_rule TEXT,
        recurrence_end_at TEXT,
        lead_days INTEGER,
        enabled INTEGER NOT NULL DEFAULT 1,
        status TEXT NOT NULL DEFAULT 'scheduled',
        snoozed_until TEXT,
        next_fire_at_utc TEXT NOT NULL,
        notification_id INTEGER,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        completed_at TEXT
      )
    ''');
    final repository = ReminderRepository(
      database: AppDatabase.forTesting(() async => database),
    );

    final when = DateTime.now().add(const Duration(days: 2));
    await repository.create(
      title: 'Renew policy',
      note: 'Check the PDF',
      remindAt: when,
    );

    final rows = await database.query('reminders');
    expect(rows, hasLength(1));
    expect(rows.single['title'], 'Renew policy');
    expect(rows.single['note'], 'Check the PDF');
    expect(rows.single['enabled'], 1);
    expect(rows.single['status'], 'scheduled');
    expect(DateTime.parse(rows.single['remind_at_utc'] as String).toUtc(),
      when.toUtc());

    await database.close();
  });
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
  test('ReminderRepository validates titles before persistence', () {
    expect(ReminderRepository.validateTitle('  Renew policy  '), 'Renew policy');
    expect(() => ReminderRepository.validateTitle(''), throwsArgumentError);
    expect(() => ReminderRepository.validateTitle('   '), throwsArgumentError);
  });
}
