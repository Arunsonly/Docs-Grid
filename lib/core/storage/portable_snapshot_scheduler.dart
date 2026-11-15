import 'dart:async';

/// Debounces durable database mutations into one portable recovery snapshot.
class PortableSnapshotScheduler {
  PortableSnapshotScheduler._();

  static final PortableSnapshotScheduler instance = PortableSnapshotScheduler._();

  Future<void> Function()? _writer;
  Timer? _timer;
  Future<void>? _inFlight;
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
      await running;
      if (_dirty) await flushNow();
      return;
    }

    if (!_dirty) return;
    final writer = _writer;
    if (writer == null) return;

    _dirty = false;
    final operation = _runWriter(writer);
    _inFlight = operation;
    await operation;
    if (identical(_inFlight, operation)) _inFlight = null;

    // A new mutation during the write gets its own debounced follow-up.
    if (_dirty && _timer == null) {
      _timer = Timer(const Duration(seconds: 3), () {
        unawaited(flushNow());
      });
    }
  }

  Future<void> _runWriter(Future<void> Function() writer) async {
    try {
      await writer();
    } catch (_) {
      // SQLite remains the source of truth. Keep the dirty bit so the next
      // mutation or app pause can retry once storage access is available.
      _dirty = true;
    }
  }
}
