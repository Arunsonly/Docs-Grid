import '../../core/database/app_database.dart';

/// Central compatibility boundary for DocsGrid portable database backups.
class BackupSchemaCompatibility {
  const BackupSchemaCompatibility._();

  static const int currentVersion = AppDatabase.schemaVersion;

  static void requireSupported(int version) {
    if (version < 1 || version > currentVersion) {
      throw FormatException(
        'Backup database schema $version is not supported. '
        'This app supports schema versions 1 through $currentVersion.',
      );
    }
  }
}
