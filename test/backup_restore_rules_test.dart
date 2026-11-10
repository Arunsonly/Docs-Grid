import 'package:docs_grid/features/tools/backup_schema_compatibility.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BackupSchemaCompatibility', () {
    test('accepts the current database schema version', () {
      expect(
        () => BackupSchemaCompatibility.requireSupported(7),
        returnsNormally,
      );
    });

    test('rejects a backup created by a newer database schema', () {
      expect(
        () => BackupSchemaCompatibility.requireSupported(8),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects invalid schema versions', () {
      expect(
        () => BackupSchemaCompatibility.requireSupported(0),
        throwsA(isA<FormatException>()),
      );
    });
  });

}
