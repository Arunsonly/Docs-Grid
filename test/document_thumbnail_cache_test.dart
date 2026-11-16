import 'package:docs_grid/features/documents/presentation/document_thumbnail.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PDF thumbnail cache keys', () {
    test('long Phone content URIs produce short, safe cache filenames', () {
      final uri = 'content://com.example.documents/tree/' +
          List<String>.filled(180, 'nested-folder-with-a-long-name').join('/');
      final name = thumbnailCacheFileName(
        documentId: 'phone_$uri',
        storagePath: uri,
        sizeBytes: 2000000,
        fingerprint: 'provider:2000000:1794811200000',
      );
      expect(name.length, lessThan(100));
      expect(name.endsWith('.png'), isTrue);
      expect(name.contains('/'), isFalse);
      expect(name.contains('\\'), isFalse);
    });

    test('keys are stable and separate sources, sizes and revisions', () {
      String key(String path, int size, String revision) =>
          thumbnailCacheFileName(
            documentId: 'phone_$path',
            storagePath: path,
            sizeBytes: size,
            fingerprint: revision,
          );
      const source = 'content://example/document/42';
      final original = key(source, 1024, 'provider:1024:1700000000000');
      expect(key(source, 1024, 'provider:1024:1700000000000'), original);
      expect(key(source, 1024, 'provider:1024:1700000001000'), isNot(original));
      expect(key(source, 2048, 'provider:2048:1700000000000'), isNot(original));
      expect(key('content://example/document/43', 1024,
          'provider:1024:1700000000000'), isNot(original));
    });
  });

  group('Phone PDF modification times', () {
    test('supports indexed milliseconds and persisted ISO-8601 dates', () {
      expect(thumbnailModifiedMillis(1700000000000), 1700000000000);
      expect(thumbnailModifiedMillis('1700000000000'), 1700000000000);
      expect(
        thumbnailModifiedMillis('2023-11-14T22:13:20.000Z'),
        1700000000000,
      );
    });
    test('ignores missing or unusable modification times', () {
      expect(thumbnailModifiedMillis(null), isNull);
      expect(thumbnailModifiedMillis(0), isNull);
      expect(thumbnailModifiedMillis('invalid'), isNull);
      expect(thumbnailModifiedMillis(-1), isNull);
    });
  });
}
