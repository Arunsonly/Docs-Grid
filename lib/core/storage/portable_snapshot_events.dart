import 'dart:async';

/// A best-effort hint for *read-only* Grid folder preview metadata.
/// null means that the affected folders cannot be proven: invalidate all
/// previews. An empty set means a metadata-only change which does not affect
/// saved folder names, direct PDF counts or sizes.
class GridFolderChange {
  GridFolderChange(Set<String?>? affectedFolderIds)
      : affectedFolderIds = affectedFolderIds == null
            ? null
            : Set<String?>.unmodifiable(affectedFolderIds);

  final Set<String?>? affectedFolderIds;
  bool get invalidateAll => affectedFolderIds == null;

  bool affects(String? folderId) =>
      invalidateAll || affectedFolderIds!.contains(folderId);
}

/// In-process change signal for coalescing portable metadata snapshots.
/// SQLite's portable_snapshot_state triggers remain the source of truth.
/// Grid preview hints are independent: they never authorize file operations.
class PortableSnapshotEvents {
  PortableSnapshotEvents._();

  static final StreamController<void> _changes =
      StreamController<void>.broadcast(sync: true);
  static final StreamController<GridFolderChange> _gridPreviewChanges =
      StreamController<GridFolderChange>.broadcast(sync: true);

  static Stream<void> get changes => _changes.stream;
  static Stream<GridFolderChange> get gridPreviewChanges =>
      _gridPreviewChanges.stream;

  /// No folder IDs means the change is ambiguous: keep the safe fallback.
  /// Passing a *verified* affected set invalidates only those preview keys;
  /// an empty set leaves previews intact (e.g. opening/favoriting a PDF).
  /// Existing portable snapshot events fire exactly as before.
  static void notifyDataChanged({Set<String?>? affectedFolderIds}) {
    if (!_changes.isClosed) _changes.add(null);
    if (!_gridPreviewChanges.isClosed) {
      _gridPreviewChanges.add(GridFolderChange(affectedFolderIds));
    }
  }
}
