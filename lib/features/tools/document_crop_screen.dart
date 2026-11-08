import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

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
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _workingImage = widget.imageBytes;
  }

  void _replaceImage(Uint8List bytes) {
    setState(() { _workingImage = bytes; _controller = CropController(); _imageVersion++; });
  }

  void _rotate() {
    final decoded = img.decodeImage(_workingImage);
    if (decoded == null) return;
    _replaceImage(Uint8List.fromList(img.encodePng(img.copyRotate(decoded, angle: 90))));
  }

  void _applyFilter(String value) {
    if (value == 'original') { _replaceImage(widget.imageBytes); return; }
    final decoded = img.decodeImage(widget.imageBytes);
    if (decoded == null) return;
    final enhanced = img.adjustColor(decoded, contrast: 1.12, brightness: 1.04, saturation: 1.04);
    _replaceImage(Uint8List.fromList(img.encodePng(enhanced)));
  }

  void _finish(CropResult result) {
    if (!mounted || _completed) return;
    switch (result) {
      case CropSuccess(:final croppedImage):
        // crop_your_image can still be notifying dependents when onCropped
        // fires. Pop only after the current frame has completed; popping
        // synchronously here caused Flutter's _dependents.isEmpty assertion
        // on some Android devices.
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Crop document'),
        leading: IconButton(
          tooltip: 'Cancel crop',
          icon: const Icon(Icons.close),
          onPressed: _cropping ? null : () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Text(
                'Move and resize the crop frame to include only the document. Pinch to zoom, then apply the crop.',
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
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                TextButton.icon(onPressed: _cropping ? null : () => Navigator.of(context).pop(), icon: const Icon(Icons.refresh), label: const Text('Retake')),
                FilledButton.icon(onPressed: _cropping ? null : () { setState(() => _cropping = true); _controller.crop(); },
                  icon: _cropping ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.crop),
                  label: Text(_cropping ? 'Cropping…' : 'Crop')),
                IconButton(tooltip: 'Rotate', onPressed: _cropping ? null : _rotate, icon: const Icon(Icons.rotate_right)),
                PopupMenuButton<String>(enabled: !_cropping, tooltip: 'Filter', onSelected: _applyFilter,
                  itemBuilder: (_) => const [PopupMenuItem(value: 'original', child: Text('Original Color')), PopupMenuItem(value: 'auto', child: Text('Auto Color'))],
                  child: const Padding(padding: EdgeInsets.all(6), child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.tune), Text('Filter', style: TextStyle(fontSize: 11))]))),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}
