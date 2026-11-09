import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// CPU-heavy image work stays off the UI isolate. Four supplied points are
/// source-image pixel coordinates in TL, TR, BL, BR order.
@visibleForTesting
Uint8List transformDocumentImageForTesting(Map<String, Object> args) {
  final bytes = args['bytes'] as Uint8List;
  final operation = args['operation'] as String;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw StateError('Could not decode this image.');
  final oriented = img.bakeOrientation(decoded);
  late img.Image output;
  switch (operation) {
    case 'rotate':
      output = img.copyRotate(oriented, angle: 90);
      break;
    case 'auto':
      // Fast document enhancement: grayscale, normalize paper tone and lift
      // ink contrast. Original pixels remain available through Reset.
      final gray = img.grayscale(oriented);
      output = img.adjustColor(gray, contrast: 1.20, brightness: 1.03, saturation: 1.05);
      break;
    case 'perspective':
      final points = (args['points'] as List).cast<num>();
      if (points.length != 8) throw ArgumentError('Four crop corners are required.');
      final tl = img.Point(points[0], points[1]);
      final tr = img.Point(points[2], points[3]);
      final bl = img.Point(points[4], points[5]);
      final br = img.Point(points[6], points[7]);
      final width = math.max(
        math.sqrt(math.pow(tr.x - tl.x, 2) + math.pow(tr.y - tl.y, 2)),
        math.sqrt(math.pow(br.x - bl.x, 2) + math.pow(br.y - bl.y, 2)),
      ).round().clamp(64, oriented.width).toInt();
      final height = math.max(
        math.sqrt(math.pow(bl.x - tl.x, 2) + math.pow(bl.y - tl.y, 2)),
        math.sqrt(math.pow(br.x - tr.x, 2) + math.pow(br.y - tr.y, 2)),
      ).round().clamp(64, oriented.height).toInt();
      output = img.copyRectify(
        oriented,
        topLeft: tl,
        topRight: tr,
        bottomLeft: bl,
        bottomRight: br,
        interpolation: img.Interpolation.linear,
        toImage: img.Image(width: width, height: height),
      );
      break;
    default:
      output = oriented;
  }
  return Uint8List.fromList(img.encodeJpg(output, quality: 94));
}

List<int> _readImageDimensions(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw StateError('Could not read image dimensions.');
  final oriented = img.bakeOrientation(decoded);
  return [oriented.width, oriented.height];
}

class DocumentCropScreen extends StatefulWidget {
  const DocumentCropScreen({super.key, required this.imageBytes});

  final Uint8List imageBytes;

  @override
  State<DocumentCropScreen> createState() => _DocumentCropScreenState();
}

class _DocumentCropScreenState extends State<DocumentCropScreen> {
  late Uint8List _workingImage;
  late Future<List<int>> _dimensions;
  List<Offset> _corners = const [
    Offset(.06, .06), Offset(.94, .06),
    Offset(.06, .94), Offset(.94, .94),
  ];
  int _activeCorner = -1;
  bool _processing = false;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _workingImage = widget.imageBytes;
    _dimensions = compute(_readImageDimensions, _workingImage);
  }

  void _replaceImage(Uint8List bytes) {
    if (!mounted) return;
    setState(() {
      _workingImage = bytes;
      _dimensions = compute(_readImageDimensions, bytes);
      _corners = const [
        Offset(.06, .06), Offset(.94, .06),
        Offset(.06, .94), Offset(.94, .94),
      ];
    });
  }

  Future<bool> _transform(String operation, {List<num>? points}) async {
    if (_processing || _completed) return false;
    setState(() => _processing = true);
    try {
      final args = <String, Object>{
        'bytes': _workingImage,
        'operation': operation,
        if (points != null) 'points': points,
      };
      final bytes = await compute(transformDocumentImageForTesting, args);
      if (mounted) _replaceImage(bytes);
      return mounted;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image processing failed: $error')),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Rect _imageRect(Size viewport, Size image) {
    final scale = math.min(viewport.width / image.width, viewport.height / image.height);
    final size = Size(image.width * scale, image.height * scale);
    return Rect.fromLTWH(
      (viewport.width - size.width) / 2,
      (viewport.height - size.height) / 2,
      size.width,
      size.height,
    );
  }

  void _moveCorner(Offset local, Rect imageRect) {
    if (_activeCorner < 0 || _processing) return;
    const inset = 22.0;
    final x = ((local.dx - imageRect.left) / imageRect.width)
        .clamp(inset / imageRect.width, 1 - inset / imageRect.width);
    final y = ((local.dy - imageRect.top) / imageRect.height)
        .clamp(inset / imageRect.height, 1 - inset / imageRect.height);
    final next = List<Offset>.from(_corners);
    next[_activeCorner] = Offset(x, y);
    setState(() => _corners = next);
  }

  int _nearestCorner(Offset local, Rect rect) {
    var nearest = -1;
    var distance = 40.0;
    for (var i = 0; i < _corners.length; i++) {
      final point = Offset(
        rect.left + _corners[i].dx * rect.width,
        rect.top + _corners[i].dy * rect.height,
      );
      final next = (point - local).distance;
      if (next < distance) {
        nearest = i;
        distance = next;
      }
    }
    return nearest;
  }

  bool _validPolygon() {
    final p = _corners;
    double cross(Offset a, Offset b, Offset c) =>
        (b.dx - a.dx) * (c.dy - b.dy) - (b.dy - a.dy) * (c.dx - b.dx);
    final ordered = [p[0], p[1], p[3], p[2]];
    final signs = <double>[];
    for (var i = 0; i < 4; i++) {
      signs.add(cross(ordered[i], ordered[(i + 1) % 4], ordered[(i + 2) % 4]));
    }
    return signs.every((v) => v > .0005) || signs.every((v) => v < -.0005);
  }

  Future<void> _crop(List<int> dimensions) async {
    if (!_validPolygon()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Adjust the corners so they form a valid four-sided shape.')),
      );
      return;
    }
    final width = dimensions[0], height = dimensions[1];
    final points = <num>[
      _corners[0].dx * (width - 1), _corners[0].dy * (height - 1),
      _corners[1].dx * (width - 1), _corners[1].dy * (height - 1),
      _corners[2].dx * (width - 1), _corners[2].dy * (height - 1),
      _corners[3].dx * (width - 1), _corners[3].dy * (height - 1),
    ];
    final succeeded = await _transform('perspective', points: points);
    if (!mounted || !succeeded) return;
    if (!_completed) {
      _completed = true;
      Navigator.of(context).pop<Uint8List>(_workingImage);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Perspective crop'),
        leading: IconButton(
          tooltip: 'Cancel crop',
          icon: const Icon(Icons.close),
          onPressed: _processing ? null : () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Text(
                'Drag each corner to the document edge. The image stays centered and the handles remain inside the screen.',
                textAlign: TextAlign.center,
              ),
            ),
            Expanded(
              child: FutureBuilder<List<int>>(
                future: _dimensions,
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final dimensions = snapshot.data!;
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final viewport = Size(constraints.maxWidth, constraints.maxHeight);
                      final rect = _imageRect(viewport, Size(dimensions[0].toDouble(), dimensions[1].toDouble()));
                      final screenPoints = _corners.map((p) => Offset(
                        rect.left + p.dx * rect.width,
                        rect.top + p.dy * rect.height,
                      )).toList();
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (details) => setState(() {
                          _activeCorner = _nearestCorner(details.localPosition, rect);
                        }),
                        onPanUpdate: (details) => _moveCorner(details.localPosition, rect),
                        onPanEnd: (_) => setState(() => _activeCorner = -1),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Positioned.fromRect(
                              rect: rect,
                              child: Image.memory(_workingImage, fit: BoxFit.fill, gaplessPlayback: true),
                            ),
                            CustomPaint(
                              painter: _PerspectiveOverlayPainter(screenPoints),
                              size: Size.infinite,
                            ),
                            if (_processing)
                              const ColoredBox(
                                color: Color(0x66000000),
                                child: Center(child: CircularProgressIndicator()),
                              ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
              child: Wrap(
                alignment: WrapAlignment.spaceEvenly,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: _processing ? null : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Cancel'),
                  ),
                  FilledButton.icon(
                    onPressed: _processing ? null : () => _cropFromFuture(),
                    icon: const Icon(Icons.crop),
                    label: const Text('Crop'),
                  ),
                  IconButton(
                    tooltip: 'Rotate 90°',
                    onPressed: _processing ? null : () => _transform('rotate'),
                    icon: const Icon(Icons.rotate_right),
                  ),
                  PopupMenuButton<String>(
                    enabled: !_processing,
                    tooltip: 'Color enhancement',
                    onSelected: (value) {
                      if (value == 'original') {
                        _replaceImage(widget.imageBytes);
                      } else {
                        _transform('auto');
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'original', child: Text('Original')),
                      PopupMenuItem(value: 'auto', child: Text('Auto Colour')),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.auto_fix_high),
                        Text('Enhance', style: TextStyle(fontSize: 11)),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _cropFromFuture() async {
    final dimensions = await _dimensions;
    if (!mounted) return;
    await _crop(dimensions);
  }
}

class _PerspectiveOverlayPainter extends CustomPainter {
  const _PerspectiveOverlayPainter(this.points);
  final List<Offset> points;

  @override
  void paint(Canvas canvas, Size size) {
    final polygon = Path()..moveTo(points[0].dx, points[0].dy);
    polygon.lineTo(points[1].dx, points[1].dy);
    polygon.lineTo(points[3].dx, points[3].dy);
    polygon.lineTo(points[2].dx, points[2].dy);
    polygon.close();
    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addPath(polygon, Offset.zero);
    canvas.drawPath(mask, Paint()..color = const Color(0x99000000));
    canvas.drawPath(
      polygon,
      Paint()
        ..color = Colors.lightGreenAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    for (final point in points) {
      canvas.drawCircle(point, 17, Paint()..color = Colors.white);
      canvas.drawCircle(
        point,
        14,
        Paint()
          ..color = Colors.blue
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
      canvas.drawCircle(point, 4, Paint()..color = Colors.blue);
    }
  }

  @override
  bool shouldRepaint(covariant _PerspectiveOverlayPainter oldDelegate) =>
      !listEquals(oldDelegate.points, points);
}
