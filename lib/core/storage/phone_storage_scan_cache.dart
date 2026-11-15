import 'dart:async';

import 'package:flutter/foundation.dart';

import 'storage_location_service.dart';

/// One session-wide, read-only index of accessible Phone PDF files.
///
/// Home and Phone share the same scan, avoiding duplicated Android directory
/// traversal when tabs change. No files or database records are modified.
class PhoneStorageScanCache extends ChangeNotifier {
  PhoneStorageScanCache({
    Future<List<Map<String, String>>> Function()? loadRoots,
    Stream<Map<String, Object?>> Function(String rootUri)? scanRoot,
  })  : _loadRoots =
            loadRoots ?? StorageLocationService.instance.accessibleStorageRoots,
        _scanRoot = scanRoot ?? StorageLocationService.instance.streamPdfFiles;

  static final PhoneStorageScanCache instance = PhoneStorageScanCache();

  final Future<List<Map<String, String>>> Function() _loadRoots;
  final Stream<Map<String, Object?>> Function(String) _scanRoot;

  List<Map<String, Object?>> _entries = const [];
  List<Map<String, Object?>> get entries => _entries;

  int pdfBytes = 0;
  int unknownSizeCount = 0;
  int inaccessibleCount = 0;
  bool isScanning = false;
  bool isComplete = false;
  bool permissionRequired = false;
  String? scanError;
  Future<void>? _inFlight;

  Future<void> scan({bool force = false}) async {
    final running = _inFlight;
    if (running != null) return running;
    if (isComplete && !force) return;
    final scanFuture = _performScan();
    _inFlight = scanFuture;
    try {
      await scanFuture;
    } finally {
      if (identical(_inFlight, scanFuture)) _inFlight = null;
    }
  }

  Future<void> _performScan() async {
    isScanning = true;
    scanError = null;
    permissionRequired = false;
    notifyListeners();

    final found = <Map<String, Object?>>[];
    final seenUris = <String>{};
    var totalBytes = 0;
    var unknown = 0;
    var inaccessible = 0;
    var failedRoots = false;
    final flushWatch = Stopwatch()..start();

    void publish({required bool completed}) {
      _entries = List<Map<String, Object?>>.unmodifiable(found);
      pdfBytes = totalBytes;
      unknownSizeCount = unknown;
      inaccessibleCount = inaccessible;
      isComplete = completed && !failedRoots;
      notifyListeners();
      flushWatch.reset();
    }

    try {
      final roots = await _loadRoots();
      if (roots.isEmpty) {
        _entries = const [];
        pdfBytes = 0;
        unknownSizeCount = 0;
        inaccessibleCount = 0;
        isComplete = false;
        permissionRequired = true;
        return;
      }

      for (final root in roots) {
        final uri = root['uri'];
        if (uri == null || uri.isEmpty) continue;
        try {
          await for (final entry in _scanRoot(uri)) {
            final entryUri = entry['uri'] as String?;
            if (entryUri == null || !seenUris.add(entryUri)) continue;
            found.add(entry);
            if (entry['isInaccessible'] == true) {
              inaccessible++;
              failedRoots = true;
            } else if (entry['isDirectory'] != true) {
              final size = (entry['sizeBytes'] as num?)?.toInt() ?? 0;
              totalBytes += size < 0 ? 0 : size;
              if (entry['sizeKnown'] == false) unknown++;
            }
            if (found.length == 1 || found.length % 64 == 0 ||
                flushWatch.elapsedMilliseconds >= 350) {
              publish(completed: false);
            }
          }
        } catch (error) {
          failedRoots = true;
          inaccessible++;
          found.add(<String, Object?>{
            'name': root['name'] ?? 'Storage',
            'uri': uri,
            'folderPath': '',
            'isDirectory': true,
            'isInaccessible': true,
            'accessError': error.toString(),
          });
        }
      }
      publish(completed: true);
    } catch (error) {
      // Keep the last successful snapshot rather than turning it into an empty
      // screen when the system provider or permission service is transiently slow.
      scanError = error.toString();
      isComplete = false;
      if (found.isNotEmpty) publish(completed: false);
    } finally {
      isScanning = false;
      notifyListeners();
    }
  }
}
