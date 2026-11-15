import 'dart:async';

import 'package:docs_grid/core/storage/phone_storage_scan_cache.dart';
import 'package:flutter_test/flutter_test.dart';

const _root = <Map<String, String>>[
  {'uri': 'content://storage/root', 'name': 'Phone'},
];

Map<String, Object?> _pdf(String name, int size) => {
  'name': name,
  'uri': 'content://storage/$name',
  'folderPath': 'Documents',
  'sizeBytes': size,
  'sizeKnown': true,
  'isDirectory': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('concurrent Home and Phone requests share one storage walk', () async {
    var scans = 0;
    final controller = StreamController<Map<String, Object?>>();
    final cache = PhoneStorageScanCache(
      loadRoots: () async => _root,
      scanRoot: (_) {
        scans++;
        return controller.stream;
      },
    );

    final first = cache.scan();
    final second = cache.scan();
    await Future<void>.delayed(Duration.zero);
    expect(scans, 1);
    expect(cache.isScanning, isTrue);

    controller.add(_pdf('example.pdf', 100));
    await controller.close();
    await Future.wait([first, second]);

    expect(cache.isComplete, isTrue);
    expect(cache.pdfBytes, 100);
    expect(cache.entries, hasLength(1));

    await cache.scan();
    expect(scans, 1, reason: 'Changing screens must not rescan completed storage');
    cache.dispose();
  });

  test('permission-needed state does not masquerade as empty storage', () async {
    var allowed = false;
    final cache = PhoneStorageScanCache(
      loadRoots: () async => allowed ? _root : <Map<String, String>>[],
      scanRoot: (_) async* { yield _pdf('restored.pdf', 42); },
    );
    await cache.scan();
    expect(cache.permissionRequired, isTrue);
    expect(cache.isComplete, isFalse);

    allowed = true;
    await cache.scan();
    expect(cache.permissionRequired, isFalse);
    expect(cache.isComplete, isTrue);
    expect(cache.pdfBytes, 42);
    cache.dispose();
  });

  test('first discovered PDF appears before deeper folders finish scanning', () async {
    final incoming = StreamController<Map<String, Object?>>();
    final cache = PhoneStorageScanCache(
      loadRoots: () async => _root,
      scanRoot: (_) => incoming.stream,
    );
    final running = cache.scan();
    await Future<void>.delayed(Duration.zero);

    incoming.add(_pdf('early.pdf', 125));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(cache.entries, hasLength(1));
    expect(cache.pdfBytes, 125);
    expect(cache.isScanning, isTrue);
    expect(cache.isComplete, isFalse);

    await incoming.close();
    await running;
    cache.dispose();
  });

  test('partially inaccessible scan remains cached across tab switches', () async {
    var walks = 0;
    final cache = PhoneStorageScanCache(
      loadRoots: () async => _root,
      scanRoot: (_) async* {
        walks++;
        yield _pdf('readable.pdf', 300);
        yield {
          'name': 'Protected',
          'uri': 'content://storage/protected',
          'isDirectory': true,
          'isInaccessible': true,
        };
      },
    );
    await cache.scan();
    expect(cache.isComplete, isFalse);
    expect(cache.inaccessibleCount, 1);
    expect(cache.hasSettledScan, isTrue);

    await cache.scan();
    expect(walks, 1);
    await cache.scan(force: true);
    expect(walks, 2);
    cache.dispose();
  });

  test('forced refresh preserves the last successful snapshot until the new scan completes', () async {
    var runs = 0;
    final pending = StreamController<Map<String, Object?>>();
    final cache = PhoneStorageScanCache(
      loadRoots: () async => _root,
      scanRoot: (_) {
        runs++;
        if (runs == 1) return Stream.value(_pdf('old.pdf', 100));
        return pending.stream;
      },
    );
    await cache.scan();
    final update = cache.scan(force: true);
    await Future<void>.delayed(Duration.zero);

    expect(cache.entries.single['name'], 'old.pdf');
    expect(cache.isScanning, isTrue);
    pending.add(_pdf('new.pdf', 70));
    await pending.close();
    await update;

    expect(cache.entries.single['name'], 'new.pdf');
    expect(cache.pdfBytes, 70);
    cache.dispose();
  });
}
