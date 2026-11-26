import 'dart:async';

import 'folder_preview_cache.dart';

/// A best-effort hint for *read-only* Grid folder preview metadata.
/// null means that the affected folders cannot be proven: invalidate all
/// previews. An empty set means a metadata-only change which does not affect
/// saved folder names, direct PDF counts or sizes.
class GridFolderChange {
  GridFolderChange(Set<String?>? affectedFolderIds, {this.precise = false})
      : affectedFolderIds = affectedFolderIds == null
            ? null
            : Set<String?>.unmodifiable(affectedFolderIds);

  final Set<String?>? affectedFolderIds;
  final bool precise;
  bool get invalidateAll => affectedFolderIds == null;

  bool affects(String? folderId) =>
      invalidateAll || affectedFolderIds!.contains(folderId);
}

/// In-process change signal for coalescing portable metadata snapshots.
/// SQLite's portable_snapshot_state triggers remain the source of truth.
/// Grid preview hints are independent: they never authorize file operations.
class PortableSnapshotEvents {
  PortableSnapshotEvents._();

  static final StreamController<void> _gridWatchRefreshes = StreamController<void>.broadcast(sync: true);
  static final StreamController<void> _changes =
      StreamController<void>.broadcast(sync: true);
  static final StreamController<GridFolderChange> _gridPreviewChanges =
      StreamController<GridFolderChange>.broadcast(sync: true);

  // Even if no Grid screen is mounted, persistent previews must still be
  // invalidated after an import/move/restore. Batch rapid changes and keep
  // backup snapshot notifications independent.
  static Timer? _unmountedPreviewDebounce;
  static Set<String?>? _unmountedPreviewIds = <String?>{};

  static void _invalidateWhenGridIsUnmounted(Set<String?>? ids) {
    if (ids != null && ids.isEmpty) return;
    if (ids == null) {
      _unmountedPreviewIds = null;
    } else {
      _unmountedPreviewIds?.addAll(ids);
    }
    _unmountedPreviewDebounce?.cancel();
    _unmountedPreviewDebounce =
        Timer(const Duration(milliseconds: 120), () {
      final targets = _unmountedPreviewIds;
      _unmountedPreviewIds = <String?>{};
      unawaited(FolderPreviewCache.invalidateGridFolders(targets));
    });
  }

  static Stream<void> get changes => _changes.stream;
  static Stream<void> get gridWatchRefreshes => _gridWatchRefreshes.stream;
  static Stream<GridFolderChange> get gridPreviewChanges =>
      _gridPreviewChanges.stream;

  /// No folder IDs means the change is ambiguous: keep the safe fallback.
  /// Passing a *verified* affected set invalidates only those preview keys;
  /// an empty set leaves previews intact (e.g. opening/favoriting a PDF).
  /// Existing portable snapshot events fire exactly as before.
  static void notifyDataChanged({Set<String?>? affectedFolderIds,
    bool preciseGridFolders = false}) {
    if (!_changes.isClosed) _changes.add(null);
    if (!preciseGridFolders && (affectedFolderIds == null || affectedFolderIds.isNotEmpty)) {
      _gridWatchRefreshes.add(null);
    }
    notifyGridPreviewChanged(affectedFolderIds, precise: preciseGridFolders);
  }

  // Local availability is derived, not portable metadata. Do not wake up
  // snapshot writers and unrelated Home readers for external delete/restore.
  static void notifyGridPreviewChanged(Set<String?>? affectedFolderIds,
      {bool precise = false}) {
    if (!_gridPreviewChanges.isClosed) {
      if (!_gridPreviewChanges.hasListener) {
        _invalidateWhenGridIsUnmounted(affectedFolderIds);
      }
      _gridPreviewChanges.add(GridFolderChange(affectedFolderIds, precise: precise));
    }
  }
}
