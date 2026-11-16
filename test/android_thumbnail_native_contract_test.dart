import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android PDF preview copy can verify its private staging file', () {
    final source = File('platform/android/MainActivity.kt').readAsStringSync();
    final start = source.indexOf('"copyPdfToPath" -> {');
    final end = source.indexOf('"sha256Pdf" -> {', start);
    expect(start, greaterThan(-1));
    expect(end, greaterThan(start));
    final copyCode = source.substring(start, end);
    expect(copyCode, contains('openPdfSource(source, allowAppPrivateFile = true)'));
    expect(copyCode, contains('digest(source, allowAppPrivateFile = true)'));
    expect(copyCode, contains(
        'digest(Uri.fromFile(temporary), allowAppPrivateFile = true)'));
  });
}
