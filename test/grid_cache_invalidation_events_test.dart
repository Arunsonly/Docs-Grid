import 'package:docs_grid/core/storage/portable_snapshot_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a precisely identified Grid folder does not invalidate its siblings', () {
    final source = <String?>{'folder-A', null};
    final change = GridFolderChange(source);
    source.add('folder-B');
    expect(change.invalidateAll, isFalse);
    expect(change.affects('folder-A'), isTrue);
    expect(change.affects(null), isTrue);
    expect(change.affects('folder-B'), isFalse);
  });

  test('unscoped changes use safe fallback; metadata-only changes retain previews', () {
    expect(GridFolderChange(null).invalidateAll, isTrue);
    expect(GridFolderChange(null).affects('any-folder'), isTrue);
    expect(GridFolderChange(<String?>{}).invalidateAll, isFalse);
    expect(GridFolderChange(<String?>{}).affects(null), isFalse);
  });

  test('portable backup notifications are not dropped or changed by scoped preview hints', () async {
    final previews = <GridFolderChange>[];
    var snapshotEvents = 0;
    final a = PortableSnapshotEvents.gridPreviewChanges.listen(previews.add);
    final b = PortableSnapshotEvents.changes.listen((_) => snapshotEvents++);
    addTearDown(a.cancel);
    addTearDown(b.cancel);

    PortableSnapshotEvents.notifyDataChanged(
      affectedFolderIds: <String?>{'folder-A'},
    );
    PortableSnapshotEvents.notifyDataChanged(
      affectedFolderIds: <String?>{},
    );
    PortableSnapshotEvents.notifyDataChanged();

    expect(snapshotEvents, 3);
    expect(previews, hasLength(3));
    expect(previews[0].affects('folder-A'), isTrue);
    expect(previews[0].affects('folder-B'), isFalse);
    expect(previews[1].affects('folder-A'), isFalse);
    expect(previews[2].invalidateAll, isTrue);
  });
}
