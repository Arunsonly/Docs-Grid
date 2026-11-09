import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../documents/data/document_repository.dart';
import '../folders/data/folder_repository.dart';
import 'document_tools_service.dart';

/// Dedicated capture workflow. Camera/gallery launches directly into page
/// capture and crop instead of routing through the general tools dashboard.
class DocumentScannerScreen extends StatefulWidget {
  const DocumentScannerScreen({super.key, required this.useCamera});
  final bool useCamera;

  @override
  State<DocumentScannerScreen> createState() => _DocumentScannerScreenState();
}

class _DocumentScannerScreenState extends State<DocumentScannerScreen> {
  bool _busy = true;
  String? _message;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _capture());
  }

  Future<void> _capture() async {
    if (_finished || !mounted) return;
    setState(() { _busy = true; _message = null; });
    File? staged;
    try {
      staged = await DocumentToolsService().scanToPdf(
        context: context,
        useCamera: widget.useCamera,
      );
      if (!mounted || staged == null) {
        _finish();
        return;
      }
      final nameController = TextEditingController(
        text: p.basenameWithoutExtension(staged.path),
      );
      final name = await showDialog<String?>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Save scanned PDF'),
          content: TextField(
            controller: nameController,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'PDF name', suffixText: '.pdf'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, nameController.text.trim()), child: const Text('Continue')),
          ],
        ),
      );
      nameController.dispose();
      if (!mounted || name == null) {
        _finish();
        return;
      }
      final folders = await FolderRepository().allFoldersWithPaths();
      if (!mounted) return;
      final destination = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            const ListTile(title: Text('Save into DocsGrid folder')),
            ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('My Documents (root)'),
              onTap: () => Navigator.pop(sheetContext, ''),
            ),
            for (final folder in folders)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(folder.path),
                onTap: () => Navigator.pop(sheetContext, folder.folder.id),
              ),
          ]),
        ),
      );
      if (!mounted || destination == null) {
        _finish();
        return;
      }
      final result = await DocumentRepository().importScannedPdf(
        staged,
        displayName: name.isEmpty ? null : name,
        targetFolderId: destination.isEmpty ? null : destination,
        sourceType: widget.useCamera ? 'camera' : 'gallery',
      );
      if (!mounted) return;
      setState(() => _message = result.added == 1
          ? 'PDF saved in DocsGrid.'
          : result.duplicates > 0
              ? 'This PDF already exists in your library.'
              : 'PDF could not be added.');
      _finished = true;
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = 'Scan could not be completed: $error';
          _busy = false;
        });
      }
      _finished = false;
    } finally {
      if (staged != null) {
        try { if (await staged.exists()) await staged.delete(); } catch (_) {}
      }
      if (mounted && !_finished) setState(() => _busy = false);
    }
  }

  void _finish() {
    if (!mounted) return;
    _finished = true;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.useCamera ? 'Document scanner' : 'Gallery to PDF'),
      leading: IconButton(
        tooltip: 'Cancel',
        onPressed: _busy ? null : _finish,
        icon: const Icon(Icons.close),
      ),
    ),
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(widget.useCamera ? Icons.document_scanner_outlined : Icons.photo_library_outlined, size: 52),
          const SizedBox(height: 16),
          if (_busy) const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(_message ?? (widget.useCamera
              ? 'Capture pages, arrange them, crop each page and save one PDF.'
              : 'Choose photos, arrange them, crop each page and save one PDF.'),
              textAlign: TextAlign.center),
          if (!_busy && !_finished) ...[
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: _capture, icon: const Icon(Icons.refresh), label: const Text('Try again')),
          ],
        ]),
      ),
    ),
  );
}
