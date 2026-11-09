import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

/// Opens PDFs with page-at-a-time rendering and pinch zoom. PdfViewPinch
/// requests pages as they enter the viewport instead of rasterizing the whole
/// document into one large bitmap.
class DocumentPdfViewerScreen extends StatefulWidget {
  const DocumentPdfViewerScreen({
    super.key,
    required this.filePath,
    required this.title,
  });

  final String filePath;
  final String title;

  @override
  State<DocumentPdfViewerScreen> createState() => _DocumentPdfViewerScreenState();
}

class _DocumentPdfViewerScreenState extends State<DocumentPdfViewerScreen> {
  late final PdfControllerPinch _controller;
  int _page = 1;
  int? _pageCount;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _controller = PdfControllerPinch(
      document: PdfDocument.openFile(widget.filePath),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Previous page',
            onPressed: _page > 1
                ? () => _controller.previousPage(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut)
                : null,
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            tooltip: 'Next page',
            onPressed: _pageCount != null && _page < _pageCount!
                ? () => _controller.nextPage(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut)
                : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.picture_as_pdf_outlined, size: 42),
                    const SizedBox(height: 12),
                    const Text('This PDF could not be rendered.'),
                    const SizedBox(height: 8),
                    Text(' $_error', textAlign: TextAlign.center),
                  ],
                ),
              ),
            )
          : PdfViewPinch(
              controller: _controller,
              onPageChanged: (page) {
                if (mounted) setState(() => _page = page);
              },
              onDocumentLoaded: (document) {
                if (mounted) {
                  setState(() {
                    _pageCount = document.pagesCount;
                    _error = null;
                  });
                }
              },
              onDocumentError: (error) {
                if (mounted) setState(() => _error = error);
              },
              builders: PdfViewPinchBuilders<DefaultBuilderOptions>(
                options: const DefaultBuilderOptions(),
                documentLoaderBuilder: (_) => const Center(
                  child: CircularProgressIndicator(),
                ),
                pageLoaderBuilder: (_) => const Center(
                  child: CircularProgressIndicator(),
                ),
                errorBuilder: (_, error) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('PDF page error: $error'),
                  ),
                ),
              ),
            ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: Text(
              _pageCount == null ? 'Loading PDF…' : 'Page $_page of $_pageCount',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        ),
      ),
    );
  }
}
