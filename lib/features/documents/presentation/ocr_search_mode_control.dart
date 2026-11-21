import 'package:flutter/material.dart';

/// Search-mode choice is always local to the current search screen.
/// A global setting may show this control; it never selects OCR for the user.
class OcrSearchModeControl extends StatelessWidget {
  const OcrSearchModeControl({
    super.key,
    required this.searchInsidePdf,
    required this.onChanged,
  });

  final bool searchInsidePdf;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return PopupMenuButton<bool>(
      key: const ValueKey('ocr-search-mode-selector'),
      tooltip: 'Choose PDF search mode',
      onSelected: onChanged,
      itemBuilder: (context) => [
        CheckedPopupMenuItem<bool>(
          value: false,
          checked: !searchInsidePdf,
          child: const Text('File name'),
        ),
        CheckedPopupMenuItem<bool>(
          value: true,
          checked: searchInsidePdf,
          child: const Text('OCR text'),
        ),
      ],
      child: Semantics(
        label: searchInsidePdf
            ? 'OCR search active. Choose search type'
            : 'OCR search inactive. Choose search type',
        button: true,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: searchInsidePdf
                ? primary
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.document_scanner_outlined, size: 15,
                color: searchInsidePdf ? Colors.white : primary),
              const SizedBox(width: 4),
              Text('OCR', style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700,
                color: searchInsidePdf ? Colors.white : primary,
              )),
              Icon(Icons.arrow_drop_down, size: 16,
                color: searchInsidePdf ? Colors.white : primary),
            ],
          ),
        ),
      ),
    );
  }
}
