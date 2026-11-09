import 'dart:typed_data';

import 'package:docs_grid/features/tools/document_crop_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List _fixture() {
  final image = img.Image(width: 120, height: 100);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      image.setPixelRgb(x, y, x * 2, y * 2, 180);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 95));
}

void main() {
  test('four-corner perspective correction returns a rectified page', () {
    final output = transformDocumentImageForTesting({
      'bytes': _fixture(),
      'operation': 'perspective',
      // TL, TR, BL, BR: a trapezoid inside the 120x100 source image.
      'points': <num>[12, 8, 106, 14, 6, 91, 112, 86],
    });
    final decoded = img.decodeImage(output)!;
    expect(decoded.width, greaterThan(64));
    expect(decoded.height, greaterThan(64));
    expect(decoded.width, lessThanOrEqualTo(120));
    expect(decoded.height, lessThanOrEqualTo(100));
  });

  test('auto colour enhancement preserves image dimensions and colour data', () {
    final source = _fixture();
    final output = transformDocumentImageForTesting({
      'bytes': source,
      'operation': 'auto',
    });
    final originalImage = img.decodeImage(source)!;
    final enhancedImage = img.decodeImage(output)!;
    expect(enhancedImage.width, originalImage.width);
    expect(enhancedImage.height, originalImage.height);
    expect(output, isNot(equals(source)));
  });

  test('rotate operation remains available after crop engine upgrade', () {
    final output = transformDocumentImageForTesting({
      'bytes': _fixture(),
      'operation': 'rotate',
    });
    final decoded = img.decodeImage(output)!;
    expect(decoded.width, 100);
    expect(decoded.height, 120);
  });
}
