import 'dart:async';

/// Serializes new library writes behind a one-time storage migration.
class StorageMigrationGate {
  StorageMigrationGate._();

  static Future<void>? _inFlight;
  static Object? _failure;

  static Future<void> start(Future<void> Function() migration) {
    final active = _inFlight;
    if (active != null) return active;
    _failure = null;
    final operation = Future<void>.sync(migration);
    _inFlight = operation;
    unawaited(operation.then<void>(
      (_) {
        if (identical(_inFlight, operation)) _inFlight = null;
      },
      onError: (Object error, StackTrace stackTrace) {
        _failure = error;
        if (identical(_inFlight, operation)) _inFlight = null;
      },
    ));
    return operation;
  }

  static Future<void> waitUntilReady() async {
    final active = _inFlight;
    if (active != null) await active;
    if (_failure != null) {
      throw StateError('The old library could not be moved yet. Restart DocsGrid to retry.');
    }
  }
}
