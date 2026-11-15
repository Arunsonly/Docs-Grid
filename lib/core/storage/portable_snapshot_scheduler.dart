import 'dart:async';

/// Debounces durable database mutations into one portable recovery snapshot.
class PortableSnapshotScheduler {
  PortableSnapshotScheduler._();

  static final PortableSnapshotScheduler instance = PortableSnapshotScheduler._();

  Future<void> Function()? _writer;
  Timer? _timer;
  Future<bool>? _inFlight;
  bool _dirty = false;

  void configure(Future<void> Function() writer) {
    _writer = writer;
  }

  void touch() {
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 3), () {
      unawaited(flushNow());
    });
  }

  Future<void> flushNow() async {
    _timer?.cancel();
    _timer = null;

    final running = _inFlight;
    if (running != null) {
      final succeeded = await running;
      // A mutation may have arrived while the writer was active and its timer
      // may have been cancelled by this flush (for example during app pause).
      if (succeeded && _dirty && _timer == null) {
        await flushNow();
      }
      return;
    }

    if (!_dirty) return;
    final writer = _writer;
    if (writer == null) return;

    _dirty = false;
    late final Future<bool> operation;
    operation = _runWriter(writer).whenComplete(() {
      if (identical(_inFlight, operation)) _inFlight = null;
    });
    _inFlight = operation;
    final succeeded = await operation;

    // Do not retry a failed permission/storage write in a tight loop. A later
    // mutation, lifecycle pause, or manual backup can retry the dirty state.
    if (succeeded && _dirty && _timer == null) {
      _timer = Timer(const Duration(seconds: 3), () {
        unawaited(flushNow());
      });
    }
  }

  Future<bool> _runWriter(Future<void> Function() writer) async {
    try {
      await writer();
      return true;
    } catch (_) {
      // SQLite remains the source of truth. Keep the dirty bit so the next
      // mutation or app pause can retry once storage access is available.
      _dirty = true;
      return false;
    }
  }
}
