import 'package:flutter/services.dart';

/// Keeps the first actionable reasons for on-device PDF recovery failures.
/// Nothing is uploaded, logged remotely, or persisted with document metadata.
class PdfRecoveryFailureReport {
  final Map<String, int> _reasons = <String, int>{};

  int get totalFailures => _reasons.values.fold<int>(0, (a, b) => a + b);

  void record(String stage, Object error) {
    // PlatformException preserves Android's actual error code/message.
    // Present the underlying failure rather than guessing from an all-failed
    // count. Bound screen text and avoid embedding multiline stack traces.
    final cause = error is PlatformException
        ? '${error.code}: ${error.message ?? 'Storage operation failed.'}'
        : error.toString();
    final oneLine = cause.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
    final bounded = oneLine.length > 240
        ? '${oneLine.substring(0, 240)}…' : oneLine;
    final reason = '$stage — $bounded';
    _reasons.update(reason, (count) => count + 1, ifAbsent: () => 1);
  }

  /// Groups identical failures so 100 PDFs do not produce 100 error dialogs.
  String get summary {
    if (_reasons.isEmpty) return '';
    final top = _reasons.entries.toList(growable: false)
      ..sort((a, b) {
        final countOrder = b.value.compareTo(a.value);
        return countOrder != 0 ? countOrder : a.key.compareTo(b.key);
      });
    final preview = top.take(3).map((e) => '${e.value}× ${e.key}').join('; ');
    final omittedKinds = top.length - 3;
    return omittedKinds > 0
        ? '$preview; plus $omittedKinds other failure types'
        : preview;
  }
}
