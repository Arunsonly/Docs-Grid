import 'dart:io';

import 'package:docs_grid/core/storage/old_docsgrid_source_discovery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('docsgrid_old_scan_');
  });
  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('empty freshly initialized tree does NOT count as old user data', () async {
    final old = Directory(p.join(temporary.path, 'Android', 'media',
        'com.docsgrid.mobile'));
    for (final folder in [
      'My Files/Unfiled', 'My Files/Folders', 'System/Database',
      'System/Recovery', 'System/Backups/Full', 'System/Logs',
    ]) {
      await Directory(p.join(old.path, folder)).create(recursive: true);
    }
    final result = await OldDocsGridSourceDiscovery.inspect(old);
    expect(result, isNull);
  });

  test('existing completed metadata snapshot activates first-launch choice', () async {
    final old = Directory(p.join(temporary.path, 'com.docsgrid.mobile'));
    final snapshot = Directory(p.join(old.path, 'System', 'Database',
        'snapshot_20260101'));
    await snapshot.create(recursive: true);
    final manifest = File(p.join(snapshot.path, 'manifest.json'));
    await manifest.writeAsString('''{"format":"DocsGridPortableData", "formatVersion":1, "tables":{"documents":1,"folders":0}}''');
    final found = await OldDocsGridSourceDiscovery.inspect(old);
    expect(found, isNotNull);
    expect(found!['detectedSnapshot'], 'true');
    expect(found['databaseUri'], contains('System/Database'));
    expect(await manifest.readAsString(), contains('DocsGridPortableData'),
        reason: 'Discovery must not mutate existing snapshots');
  });

  test('incomplete snapshot must not count as recoverable data', () async {
    final old = Directory(p.join(temporary.path, 'DocsGrid'));
    await Directory(p.join(old.path, 'Database', 'snapshot_incomplete'))
        .create(recursive: true);
    expect(await OldDocsGridSourceDiscovery.inspect(old), isNull);
  });

  test('previous PDF can be detected without an archived backup', () async {
    final old = Directory(p.join(temporary.path, 'DocsGrid'));
    final pdf = File(p.join(old.path, 'Folders', 'Insurance',
        'policy.pdf'));
    await pdf.parent.create(recursive: true);
    await pdf.writeAsString('%PDF-1.4\nold bytes');
    final found = await OldDocsGridSourceDiscovery.inspect(old);
    expect(found, isNotNull);
    expect(found!['detectedPdfs'], 'true');
    expect(found['libraryUri'], contains('/Folders/'));
    expect(await pdf.readAsString(), '%PDF-1.4\nold bytes');
  });

  test('previous A001 backup series is detected but not rewritten', () async {
    final old = Directory(p.join(temporary.path, 'com.docsgrid.mobile'));
    final base = File(p.join(old.path, 'System', 'Backups',
        'Full', 'A001', 'A001.zip'));
    await base.parent.create(recursive: true);
    await base.writeAsString('old ZIP placeholder');
    final found = await OldDocsGridSourceDiscovery.inspect(old);
    expect(found, isNotNull);
    expect(found!['detectedBackup'], 'true');
    expect(await base.readAsString(), 'old ZIP placeholder');
  });

  test('a random unrelated folder is NOT a valid DocsGrid source', () async {
    final other = Directory(p.join(temporary.path, 'Downloads'));
    await other.create();
    await File(p.join(other.path, 'notes.txt')).writeAsString('hello');
    expect(await OldDocsGridSourceDiscovery.inspect(other), isNull);
  });
}
