import 'package:docs_grid/features/documents/data/phone_pdf_delta.dart';
import 'package:docs_grid/core/storage/storage_location_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('storage change listeners share the same native broadcast stream', () {
    final service = StorageLocationService.instance;
    final phone = service.storageChanges;
    final grid = service.storageChanges;
    expect(phone.isBroadcast, isTrue);
    expect(identical(phone, grid), isTrue);
  });

  Map<String, Object?> pdf(
    String uri, String name, String folder, {
    int size = 100,
    String volume = 'external_primary',
  }) => {
    'uri': uri,
    'name': name,
    'folderPath': folder,
    'volumeName': volume,
    'isDirectory': false,
    'sizeBytes': size,
  };

  test('adds only a new MediaStore PDF; other rows retain identity', () {
    final prior = pdf('content://media/external_primary/file/1',
        'first.pdf', 'Internal/Download');
    final saf = <String, Object?>{
      'uri': 'content://tree/cloud/document/1',
      'name': 'cloud.pdf',
      'folderPath': 'Granted folder 1',
    };
    final existing = [prior, saf];
    final added = pdf('content://media/external_primary/file/2',
        'added.pdf', 'Internal/Download');
    final delta = PhonePdfDelta.apply(
      existing: existing,
      updates: [added],
      touchedMediaUris: [added['uri'] as String],
      touchedLocalPaths: ['Internal/Download/added.pdf'],
    );
    expect(delta.changed, isTrue);
    expect(delta.entries, hasLength(3));
    expect(identical(delta.entries[0], prior), isTrue);
    expect(identical(delta.entries[1], saf), isTrue);
    expect(delta.entries.last['name'], 'added.pdf');
    expect(existing, hasLength(2));
  });

  test('deletes only the exact item URI, never an unrelated provider PDF', () {
    final media = pdf('content://media/external_primary/file/1',
        'shared.pdf', 'Internal/Download');
    final saf = <String, Object?>{
      'uri': 'content://tree/cloud/1',
      'name': 'shared.pdf',
      'folderPath': 'Internal/Download',
    };
    final delta = PhonePdfDelta.apply(
      existing: [media, saf],
      updates: const [],
      touchedMediaUris: [media['uri'] as String],
      touchedLocalPaths: const [],
    );
    expect(delta.entries, [saf]);
  });

  test('local path deletion removes only matching primary MediaStore row', () {
    final a = pdf('content://media/external_primary/file/1',
        'a.pdf', 'Internal/Documents');
    final b = pdf('content://media/external_primary/file/2',
        'b.pdf', 'Internal/Documents');
    final sd = pdf('content://media/SD/file/3',
        'a.pdf', 'External storage 1/Documents', volume: 'SD');
    final delta = PhonePdfDelta.apply(
      existing: [a, b, sd],
      updates: const [],
      touchedMediaUris: const [],
      touchedLocalPaths: const ['Internal/Documents/a.pdf'],
    );
    expect(delta.entries.map((e) => e['uri']), [b['uri'], sd['uri']]);
  });

  test('replaces changed size and folder without duplicate URI', () {
    final old = pdf('content://media/external_primary/file/1',
        'a.pdf', 'Internal/Download');
    final updated = pdf('content://media/external_primary/file/1',
        'a.pdf', 'Internal/Documents', size: 9000);
    final result = PhonePdfDelta.apply(
      existing: [old],
      updates: [updated],
      touchedMediaUris: [old['uri'] as String],
      touchedLocalPaths: const [],
    );
    expect(result.entries, hasLength(1));
    expect(result.entries.single['folderPath'], 'Internal/Documents');
    expect(result.entries.single['sizeBytes'], 9000);
  });

  test('unchanged row is a true no-op with identical list', () {
    final old = pdf('content://media/external_primary/file/1',
        'same.pdf', 'Internal/Download');
    final current = [old];
    final result = PhonePdfDelta.apply(
      existing: current,
      updates: [Map<String, Object?>.from(old)],
      touchedMediaUris: [old['uri'] as String],
      touchedLocalPaths: const [],
    );
    expect(result.changed, isFalse);
    expect(identical(result.entries, current), isTrue);
    expect(identical(result.entries.single, old), isTrue);
  });

  test('MediaStore version/volume mismatch triggers full scan', () {
    const previous = <String, Object?>{
      'external_primary': {
        'version': 'old-v1',
        'generation': 20,
        'label': 'Internal',
      },
    };
    const normal = <String, Object?>{
      'external_primary': {
        'version': 'old-v1',
        'generation': 21,
        'label': 'Internal',
      },
    };
    const reset = <String, Object?>{
      'external_primary': {
        'version': 'new-v2',
        'generation': 1,
        'label': 'Internal',
      },
    };
    expect(PhonePdfDelta.volumesAreCompatible(
      previous: previous,
      observed: normal,
      mounted: ['external_primary'],
    ), isTrue);
    expect(PhonePdfDelta.volumesAreCompatible(
      previous: previous,
      observed: reset,
      mounted: ['external_primary'],
    ), isFalse);
    expect(PhonePdfDelta.volumesAreCompatible(
      previous: previous,
      observed: normal,
      mounted: ['external_primary', 'SD'],
    ), isFalse);
    expect(PhonePdfDelta.volumesAreCompatible(
      previous: previous,
      observed: const {
        'external_primary': {
          'version': 'old-v1',
          'generation': 10,
          'label': 'Internal',
        },
      },
      mounted: ['external_primary'],
    ), isFalse);
  });

  test('unknown or legacy events force full reconciliation', () {
    expect(StorageChangeNotice.fromPlatform(null).requiresFullRefresh, isTrue);
    expect(StorageChangeNotice.fromPlatform({
      'mediaUris': <String>[],
      'paths': <String>[],
      'requiresFullRefresh': false,
    }).requiresFullRefresh, isTrue);
    final notice = StorageChangeNotice.fromPlatform({
      'mediaUris': ['content://media/external_primary/file/12'],
      'paths': ['/storage/emulated/0/Download/a.pdf'],
      'requiresFullRefresh': false,
    });
    expect(notice.requiresFullRefresh, isFalse);
    expect(notice.mediaUris, hasLength(1));
    expect(notice.paths, hasLength(1));
  });

  test('deleted folder placeholder and unknown provider record stay intact', () {
    final pendingFolder = <String, Object?>{
      'uri': 'content://tree/recycle',
      'name': 'Download',
      'path': 'Internal/Download',
      'isDirectory': true,
      'isPending': true,
      'trashPdfCount': 1,
    };
    final old = pdf('content://media/external_primary/file/1',
        'gone.pdf', 'Internal/Download');
    final result = PhonePdfDelta.apply(
      existing: [pendingFolder, old],
      updates: const [],
      touchedMediaUris: const [],
      touchedLocalPaths: ['Internal/Download/gone.pdf'],
    );
    expect(result.entries, hasLength(1));
    expect(identical(result.entries.single, pendingFolder), isTrue);
  });
}
