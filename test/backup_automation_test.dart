import 'package:docs_grid/core/backup/backup_automation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BackupAutomation.isBackupDue', () {
    final now = DateTime.utc(2026, 11, 11, 12);

    test('first run is due', () {
      expect(
        BackupAutomation.isBackupDue(
          status: const {'status': 'not_run'},
          now: now,
          interval: const Duration(days: 1),
          retryCooldown: const Duration(hours: 6),
        ),
        isTrue,
      );
    });

    test('successful daily backup is not repeated before its interval', () {
      expect(
        BackupAutomation.isBackupDue(
          status: const {
            'status': 'success',
            'completedAtUtc': '2026-11-11T08:00:00.000Z',
          },
          now: now,
          interval: const Duration(hours: 24),
          retryCooldown: const Duration(hours: 6),
        ),
        isFalse,
      );
    });

    test('failed weekly backup respects its retry cooldown', () {
      expect(
        BackupAutomation.isBackupDue(
          status: const {
            'status': 'failed',
            'attemptedAtUtc': '2026-11-11T06:00:00.000Z',
          },
          now: now,
          interval: const Duration(days: 7),
          retryCooldown: const Duration(hours: 24),
        ),
        isFalse,
      );
    });

    test('failed weekly backup becomes due again after retry cooldown', () {
      expect(
        BackupAutomation.isBackupDue(
          status: const {
            'status': 'failed',
            'attemptedAtUtc': '2026-11-10T00:00:00.000Z',
          },
          now: now,
          interval: const Duration(days: 7),
          retryCooldown: const Duration(hours: 24),
        ),
        isTrue,
      );
    });

    test('expired successful weekly backup is due', () {
      expect(
        BackupAutomation.isBackupDue(
          status: const {
            'status': 'success',
            'completedAtUtc': '2026-11-03T12:00:00.000Z',
          },
          now: now,
          interval: const Duration(days: 7),
          retryCooldown: const Duration(hours: 24),
        ),
        isTrue,
      );
    });
  });
}
