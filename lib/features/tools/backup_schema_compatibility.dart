/// Central compatibility boundary for DocsGrid portable database backups.
/// Keep this in sync with AppDatabase's SQLite schema version.
class BackupSchemaCompatibility {
  const BackupSchemaCompatibility._();

  static const int currentVersion = 7;

  static void requireSupported(int version) {
    if (version < 1 || version > currentVersion) {
      throw FormatException(
        'Backup database schema $version is not supported. '
        'This app supports schema versions 1 through $currentVersion.',
      );
    }
  }
}
