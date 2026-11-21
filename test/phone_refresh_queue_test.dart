import 'package:docs_grid/core/storage/storage_location_service.dart';
import 'package:docs_grid/features/documents/data/phone_refresh_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  StorageChangeNotice precise({
    List<String> uris = const [],
    List<String> paths = const [],
  }) => StorageChangeNotice(
    mediaUris: uris,
    paths: paths,
    requiresFullRefresh: false,
  );

  test('multiple events merge into one exact scoped query without duplicate paths', () {
    final pending = PhoneRefreshQueue();
    pending.add(precise(paths: ['/storage/emulated/0/Download/a.pdf']));
    pending.add(precise(
      paths: ['/storage/emulated/0/Download/a.pdf',
        '/storage/emulated/0/Download/b.pdf'],
      uris: ['content://media/external_primary/file/11'],
    ));
    expect(pending.hasPending, isTrue);
    final batch = pending.take();
    expect(batch.requiresFullRefresh, isFalse);
    expect(batch.mediaUris, ['content://media/external_primary/file/11']);
    expect(batch.paths, [
      '/storage/emulated/0/Download/a.pdf',
      '/storage/emulated/0/Download/b.pdf',
    ]);
    expect(pending.hasPending, isFalse);
    expect(pending.take().hasChanges, isFalse);
  });

  test('events received while a scan is busy remain pending until taken', () {
    final pending = PhoneRefreshQueue();
    pending.add(precise(uris: ['content://media/external_primary/file/51']));
    expect(pending.hasPending, isTrue);
    // A busy scan must not consume hints or reclassify them as unscoped.
    pending.add(precise(uris: ['content://media/external_primary/file/52']));
    final batch = pending.take();
    expect(batch.requiresFullRefresh, isFalse);
    expect(batch.mediaUris.length, 2);
  });

  test('overflow and unknown notifications fail safely to full reconciliation', () {
    final pending = PhoneRefreshQueue(maxScopedChanges: 2);
    pending.add(precise(paths: ['a', 'b']));
    pending.add(precise(paths: ['c']));
    expect(pending.take().requiresFullRefresh, isTrue);
    pending.add(precise(paths: ['a']));
    pending.add(null); // Resume or explicit safety refresh.
    pending.add(precise(paths: ['b']));
    final batch = pending.take();
    expect(batch.requiresFullRefresh, isTrue);
    expect(batch.paths, isEmpty);
    expect(batch.mediaUris, isEmpty);
  });

  test('ambiguous provider event never looks like an empty targeted deletion', () {
    final pending = PhoneRefreshQueue();
    pending.add(const StorageChangeNotice());
    final batch = pending.take();
    expect(batch.requiresFullRefresh, isTrue);
    expect(batch.hasChanges, isTrue);
  });
}
