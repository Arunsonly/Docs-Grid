import 'dart:async';

/// In-process change signal for coalescing portable metadata snapshots.
/// SQLite's portable_snapshot_state triggers remain the source of truth;
/// this stream only wakes the debounced snapshot worker promptly.
class PortableSnapshotEvents {
  PortableSnapshotEvents._();

  static final StreamController<void> _changes =
      StreamController<void>.broadcast(sync: true);

  static Stream<void> get changes => _changes.stream;

  static void notifyDataChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }
}
