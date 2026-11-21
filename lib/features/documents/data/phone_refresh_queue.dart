import '../../../core/storage/storage_location_service.dart';

/// One bounded, loss-aware batch of Phone storage change hints.
class PhoneRefreshBatch {
  const PhoneRefreshBatch({
    required this.requiresFullRefresh,
    required this.mediaUris,
    required this.paths,
  });

  final bool requiresFullRefresh;
  final List<String> mediaUris;
  final List<String> paths;

  bool get hasChanges =>
      requiresFullRefresh || mediaUris.isNotEmpty || paths.isNotEmpty;
}

/// Coalesces FileObserver and ContentObserver hints without interpreting an
/// ambiguous event as an instruction to delete PDFs. A pending scoped batch
/// stays intact when a scan or patch is busy and can be drained afterwards.
class PhoneRefreshQueue {
  PhoneRefreshQueue({this.maxScopedChanges = 48})
      : assert(maxScopedChanges > 0);

  final int maxScopedChanges;
  final Set<String> _mediaUris = <String>{};
  final Set<String> _paths = <String>{};
  bool _requiresFullRefresh = false;

  bool get hasPending => _requiresFullRefresh ||
      _mediaUris.isNotEmpty || _paths.isNotEmpty;

  void add(StorageChangeNotice? notice) {
    if (notice == null || notice.requiresFullRefresh) {
      _requiresFullRefresh = true;
      _mediaUris.clear();
      _paths.clear();
      return;
    }
    if (_requiresFullRefresh) return;
    _mediaUris.addAll(notice.mediaUris.where((value) => value.isNotEmpty));
    _paths.addAll(notice.paths.where((value) => value.isNotEmpty));
    if (_mediaUris.length + _paths.length > maxScopedChanges) {
      _requiresFullRefresh = true;
      _mediaUris.clear();
      _paths.clear();
    }
  }

  PhoneRefreshBatch take() {
    final batch = PhoneRefreshBatch(
      requiresFullRefresh: _requiresFullRefresh,
      mediaUris: List<String>.unmodifiable(_mediaUris),
      paths: List<String>.unmodifiable(_paths),
    );
    _requiresFullRefresh = false;
    _mediaUris.clear();
    _paths.clear();
    return batch;
  }
}
