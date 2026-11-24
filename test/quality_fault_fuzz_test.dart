import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:docs_grid/features/tools/backup_archive_limits.dart';
import 'package:docs_grid/features/tools/backup_folder_graph_validator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('seeded folder graph fuzz: valid ordering and malformed graph rejection', () {
    final random = Random(20261124);
    for (var iteration = 0; iteration < 40; iteration++) {
      final count = 8 + random.nextInt(80);
      final rows = List<Map<String, Object?>>.generate(count, (index) => {
        'id': 'folder-$index',
        'parent_id': index == 0 ? null : 'folder-${random.nextInt(index)}',
      });
      rows.shuffle(random);
      final ordered = BackupFolderGraphValidator.parentFirst(rows);
      expect(ordered, hasLength(count));
      final positions = <String, int>{
        for (var i = 0; i < ordered.length; i++) ordered[i]['id'] as String: i,
      };
      for (final row in ordered) {
        final parent = row['parent_id'] as String?;
        if (parent != null) {
          expect(positions[parent]!, lessThan(positions[row['id']]!));
        }
      }
      final invalid = rows.map((row) => Map<String, Object?>.from(row)).toList();
      invalid.first['parent_id'] = 'missing-parent';
      expect(() => BackupFolderGraphValidator.validate(invalid), throwsStateError);
      invalid.first['parent_id'] = invalid.first['id'];
      expect(() => BackupFolderGraphValidator.validate(invalid), throwsStateError);
      expect(() => BackupFolderGraphValidator.validate([...rows, rows.first]), throwsStateError);
    }
  });

  test('truncated ZIP fault injection rejects input without altering original', () async {
    final temporary = await Directory.systemTemp.createTemp('docsgrid-fuzz-');
    addTearDown(() async { await temporary.delete(recursive: true); });
    final archive = Archive()..addFile(ArchiveFile('metadata.json', 2, [91, 93]));
    final bytes = ZipEncoder().encode(archive);
    final original = File('${temporary.path}/original.zip');
    await original.writeAsBytes(bytes);
    await BackupArchiveLimits.validate(original);
    final random = Random(20261124);
    final damaged = File('${temporary.path}/damaged.zip');
    final lengths = <int>{0, 1, 21, bytes.length - 1};
    for (var i = 0; i < 30; i++) {
      lengths.add(random.nextInt(bytes.length));
    }
    for (final length in lengths) {
      await damaged.writeAsBytes(bytes.sublist(0, length), flush: true);
      await expectLater(BackupArchiveLimits.validate(damaged), throwsStateError);
    }
    expect(await original.readAsBytes(), orderedEquals(bytes));
    await BackupArchiveLimits.validate(original);
  });
}
