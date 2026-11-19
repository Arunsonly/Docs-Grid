import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File('platform/android/MainActivity.kt').readAsStringSync();

  test('PDF FileObserver complements existing Android MediaStore and SAF events', () {
    expect(source, contains('import android.os.FileObserver'));
    expect(source, contains('val observer = object : FileObserver('));
    expect(source, contains('contentResolver.registerContentObserver(uri, true, observer)'));
    expect(source, contains('startLocalPdfFileObservers()'));
    expect(source, contains('scheduleStorageChangeEvent()'));
    expect(source, contains('path.endsWith(".pdf", ignoreCase = true)'));
    expect(source, contains('FileObserver.CLOSE_WRITE'));
    expect(source, contains('FileObserver.MOVED_TO'));
    expect(source, contains('FileObserver.MOVED_FROM'));
    expect(source, contains('FileObserver.DELETE'));
  });

  test('FileObserver requires granted access and remains foreground only', () {
    expect(source, contains('Environment.isExternalStorageManager()'));
    expect(source, contains('if (!root.isDirectory || !root.canRead()) return'));
    expect(source, contains('private var storageObservationForeground = false'));
    expect(source, contains('if (!storageObservationForeground ||'));
    expect(source, contains('storageObservationForeground = false\n        unregisterStorageChangeObservers()'));
    expect(source, contains('stopLocalPdfFileObservers()'));
    expect(source, contains('observer.stopWatching()'));
    expect(source, contains('localPdfFileObservers.size >= 16'));
    expect(source, contains('!directory.path.startsWith(rootPrefix)'));
  });

  test('FileObserver only signals refresh and does not mutate PDF files', () {
    final start = source.indexOf('private fun startLocalPdfFileObservers()');
    final end = source.indexOf('private fun scheduleStorageChangeEvent()', start);
    expect(start, greaterThan(-1));
    expect(end, greaterThan(start));
    final watcherCode = source.substring(start, end);
    expect(watcherCode, contains('mainHandler.post {'));
    expect(watcherCode, contains('scheduleStorageChangeEvent()'));
    expect(watcherCode, isNot(contains('listStorageTreeRecursively(')));
    expect(watcherCode, isNot(contains('copyPdf(')));
    expect(watcherCode, isNot(contains('deletePdf(')));
    expect(watcherCode, isNot(contains('FileObserver.ALL_EVENTS')));
  });
}
