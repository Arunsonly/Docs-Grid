import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// Image transforms run in a worker isolate so large camera photos do not
/// block Flutter's UI thread (which previously made Rotate/Filter appear hung).
Uint8List _transformDocumentImage(Map<String, Object> args) {
  final bytes = args['bytes'] as Uint8List;
  final operation = args['operation'] as String;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw StateError('Could not decode this image.');
  late img.Image output;
  switch (operation) {
    case 'rotate':
      output = img.copyRotate(decoded, angle: 90);
      break;
    case 'auto':
      // Scanner-style monochrome enhancement: remove mild paper tint, lift
      // the paper tone and increase ink contrast. Keep the original untouched.
      final gray = img.grayscale(decoded);
      output = img.adjustColor(gray, contrast: 1.28, brightness: 1.10);
      break;
    default:
      output = decoded;
  }
  return Uint8List.fromList(img.encodeJpg(output, quality: 94));
}

class DocumentCropScreen extends StatefulWidget {
  const DocumentCropScreen({super.key, required this.imageBytes});

  final Uint8List imageBytes;

  @override
  State<DocumentCropScreen> createState() => _DocumentCropScreenState();
}

class _DocumentCropScreenState extends State<DocumentCropScreen> {
  CropController _controller = CropController();
  late Uint8List _workingImage;
  int _imageVersion = 0;
  bool _cropping = false;
  bool _processing = false;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _workingImage = widget.imageBytes;
  }

  void _replaceImage(Uint8List bytes) {
    if (!mounted) return;
    setState(() {
      _workingImage = bytes;
      _controller = CropController();
      _imageVersion++;
      _cropping = false;
    });
  }

  Future<void> _transform(String operation) async {
    if (_processing || _cropping) return;
    setState(() => _processing = true);
    try {
      final bytes = await compute(_transformDocumentImage, <String, Object>{
        'bytes': _workingImage,
        'operation': operation,
      });
      if (mounted) _replaceImage(bytes);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Image processing failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  void _applyFilter(String value) {
    if (value == 'original') {
      _replaceImage(widget.imageBytes);
    } else {
      _transform('auto');
    }
  }

  void _finish(CropResult result) {
    if (!mounted || _completed) return;
    switch (result) {
      case CropSuccess(:final croppedImage):
        _completed = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Navigator.of(context).pop<Uint8List>(croppedImage);
        });
      case CropFailure(:final cause):
        setState(() => _cropping = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not crop this image: $cause')),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _cropping || _processing;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Crop document'),
        leading: IconButton(
          tooltip: 'Cancel crop',
          icon: const Icon(Icons.close),
          onPressed: busy ? null : () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Text(
                'Adjust the corners to fit the document. Pinch to zoom, then crop.',
                textAlign: TextAlign.center,
              ),
            ),
            Expanded(
              child: Crop(
                key: ValueKey(_imageVersion),
                image: _workingImage,
                controller: _controller,
                interactive: true,
                fixCropRect: false,
                baseColor: Colors.black,
                maskColor: Colors.black.withValues(alpha: 0.55),
                radius: 12,
                onCropped: _finish,
                progressIndicator: const Center(child: CircularProgressIndicator()),
              ),
            ),
            if (_processing)
              const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
              child: Wrap(
                alignment: WrapAlignment.spaceEvenly,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: busy ? null : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retake'),
                  ),
                  FilledButton.icon(
                    onPressed: busy ? null : () {
                      setState(() => _cropping = true);
                      _controller.crop();
                    },
                    icon: _cropping
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.crop),
                    label: Text(_cropping ? 'Cropping…' : 'Crop'),
                  ),
                  IconButton(
                    tooltip: 'Rotate 90°',
                    onPressed: busy ? null : () => _transform('rotate'),
                    icon: const Icon(Icons.rotate_right),
                  ),
                  PopupMenuButton<String>(
                    enabled: !busy,
                    tooltip: 'Filter',
                    onSelected: _applyFilter,
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'original', child: Text('Original Color')),
                      PopupMenuItem(value: 'auto', child: Text('Auto Color')),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.tune),
                        Text('Filter', style: TextStyle(fontSize: 11)),
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
}
