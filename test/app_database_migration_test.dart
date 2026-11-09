import 'package:docs_grid/core/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

class _RecordingDatabase implements Database {
  final statements = <String>[];
  final inserts = <Map<String, Object?>>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #execute) {
      statements.add(invocation.positionalArguments.first as String);
      return Future<void>.value();
    }
    if (invocation.memberName == #insert) {
      inserts.add(Map<String, Object?>.from(
        invocation.positionalArguments[1] as Map,
      ));
      return Future<int>.value(1);
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  group('AppDatabase schema migrations', () {
    test('upgrades a legacy v1 database through v2 and v3', () async {
      final db = _RecordingDatabase();
      await AppDatabase.forTesting(() async => db)
          .upgradeForTesting(db, 1, 3);

      expect(
        db.statements.any((sql) => sql.contains('CREATE TABLE IF NOT EXISTS schema_migrations')),
        isTrue,
      );
      expect(db.statements.any((sql) => sql.contains('CREATE TABLE IF NOT EXISTS categories')), isTrue);
      expect(db.statements.any((sql) => sql.contains('CREATE TABLE IF NOT EXISTS tags')), isTrue);
      expect(db.statements.any((sql) => sql.contains('CREATE TABLE IF NOT EXISTS document_text_index')), isTrue);
      expect(db.statements.any((sql) => sql.contains('idx_documents_sha256')), isTrue);
      expect(
        db.inserts.where((row) => row['version'] == 2),
        hasLength(1),
      );
      expect(
        db.inserts.where((row) => row['version'] == 3),
        hasLength(1),
      );
      expect(
        db.inserts.where((row) => row['name'] == 'Insurance'),
        hasLength(1),
      );
    });

    test('v1 to v2 upgrade does not create schema v3 objects early', () async {
      final db = _RecordingDatabase();
      await AppDatabase.forTesting(() async => db)
          .upgradeForTesting(db, 1, 2);

      expect(
        db.statements.any((sql) => sql.contains('CREATE TABLE IF NOT EXISTS categories')),
        isTrue,
      );
      expect(
        db.statements.any((sql) => sql.contains('CREATE TABLE IF NOT EXISTS document_text_index')),
        isFalse,
      );
      expect(db.statements.any((sql) => sql.contains('idx_documents_sha256')), isFalse);
      expect(db.inserts.where((row) => row['version'] == 2), hasLength(1));
      expect(db.inserts.where((row) => row['version'] == 3), isEmpty);
    });

    test('upgrades a v2 database without replaying v2 table creation', () async {
      final db = _RecordingDatabase();
      await AppDatabase.forTesting(() async => db)
          .upgradeForTesting(db, 2, 3);

      expect(db.statements.any((sql) => sql.contains('CREATE TABLE IF NOT EXISTS categories')), isFalse);
      expect(db.statements.any((sql) => sql.contains('CREATE TABLE IF NOT EXISTS document_text_index')), isTrue);
      expect(db.inserts.where((row) => row['version'] == 2), isEmpty);
      expect(db.inserts.where((row) => row['version'] == 3), hasLength(1));
    });

    test('does not apply migrations when the database is already current', () async {
      final db = _RecordingDatabase();
      await AppDatabase.forTesting(() async => db)
          .upgradeForTesting(db, 3, 3);

      expect(db.statements, isEmpty);
      expect(db.inserts, isEmpty);
    });
  });
}
