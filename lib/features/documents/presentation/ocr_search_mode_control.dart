import 'package:flutter/material.dart';

/// One tap toggles OCR search. Settings only decides whether this button is
/// available; each screen starts in ordinary file-name search mode.
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
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: searchInsidePdf ? 'Turn off OCR search' : 'Turn on OCR search',
      child: Semantics(
        label: searchInsidePdf ? 'OCR search on' : 'OCR search off',
        button: true,
        toggled: searchInsidePdf,
        child: InkWell(
          key: const ValueKey('ocr-search-mode-selector'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => onChanged(!searchInsidePdf),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            decoration: BoxDecoration(
              color: searchInsidePdf
                  ? colors.primary
                  : colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: searchInsidePdf
                  ? Border.all(color: colors.primary, width: 1.5)
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.document_scanner_outlined,
                  size: 15,
                  color: searchInsidePdf
                      ? colors.onPrimary
                      : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text('OCR', style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: searchInsidePdf
                      ? colors.onPrimary
                      : colors.onSurfaceVariant,
                )),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
