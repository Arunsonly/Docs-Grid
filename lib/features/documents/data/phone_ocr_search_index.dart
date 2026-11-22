import '../../tools/document_tools_service.dart';

/// No Phone-PDF text is written to SQLite or uploaded. OCR text exists only
/// in this search-screen instance and is discarded when OCR is switched off.
typedef PhonePdfTextExtractor = Future<String> Function(
  String uri, {
  bool Function()? shouldCancel,
});

class PhoneOcrIndexSummary {
  const PhoneOcrIndexSummary({
    required this.completed,
    required this.failed,
    required this.total,
  });
  final int completed;
  final int failed;
  final int total;
}

class PhoneOcrSearchIndex {
  PhoneOcrSearchIndex(this._extractText);

  final PhonePdfTextExtractor _extractText;
  final Map<String, String> _textBySignature = {};
  final Set<String> _attempted = {};

  static String? _signature(Map<String, Object?> entry) {
    if (entry['isDirectory'] == true ||
        entry['isInaccessible'] == true ||
        entry['isInaccessibleSummary'] == true) return null;
    final uri = entry['uri'];
    final name = entry['name'];
    if (uri is! String || uri.isEmpty ||
        name is! String || !name.toLowerCase().endsWith('.pdf')) {
      return null;
    }
    return '$uri|${entry['sizeBytes'] ?? ''}|${entry['lastModified'] ?? ''}';
  }

  void clear() {
    _textBySignature.clear();
    _attempted.clear();
  }

  List<Map<String, Object?>> matches(
    Iterable<Map<String, Object?>> entries,
    String rawQuery,
  ) {
    final query = rawQuery.trim().toLowerCase();
    if (query.isEmpty) return const [];
    return entries.where((entry) {
      final signature = _signature(entry);
      return signature != null &&
          (_textBySignature[signature]?.contains(query) ?? false);
    }).toList(growable: false);
  }

  Future<PhoneOcrIndexSummary> indexEntries(
    Iterable<Map<String, Object?>> entries, {
    bool Function()? shouldCancel,
    void Function(int done, int total)? onProgress,
  }) async {
    final pending = <(String, String)>[];
    for (final entry in entries) {
      final signature = _signature(entry);
      final uri = entry['uri'];
      if (signature != null && uri is String &&
          !_attempted.contains(signature)) {
        pending.add((signature, uri));
      }
    }
    var completed = 0;
    var failed = 0;
    for (final item in pending) {
      if (shouldCancel?.call() ?? false) throw const OcrIndexCancelled();
      try {
        final extracted = await _extractText(item.$2,
            shouldCancel: shouldCancel);
        if (shouldCancel?.call() ?? false) throw const OcrIndexCancelled();
        _textBySignature[item.$1] = extracted.toLowerCase();
      } on OcrIndexCancelled {
        rethrow;
      } catch (_) {
        failed++;
        // Do not retry inaccessible PDFs for every typed character. A fresh
        // search-screen session or modified PDF will be attempted again.
      }
      _attempted.add(item.$1);
      completed++;
      onProgress?.call(completed, pending.length);
    }
    return PhoneOcrIndexSummary(
      completed: completed,
      failed: failed,
      total: pending.length,
    );
  }
}
