# OCR search and Flutter lifecycle audit

Audit date: 2026-11-09
Target: PR 18 / DocsGrid

## Findings from source inspection

### Confirmed
1. The OCR search UI previously allowed repeated taps/submissions while a previous asynchronous search was still pending.
2. The search method had no request generation token. It relied only on a mounted check after awaiting the database query.
3. The OCR indexing loop caught per-document errors without retaining or printing the exception/stack trace, so indexing failures were silently reduced to a counter.
4. Search itself is a SQLite query over document_text_index; OCR recognition is performed separately by indexPdfText/indexPdfTextFromUri. These are distinct execution paths and should not be conflated when diagnosing the reported crash.
5. OCR indexing uses pdfx to open/render every PDF page and ML Kit recognizers (Latin, plus Devanagari on Android), writing temporary PNGs and deleting them in finally blocks. Failures may therefore originate from PDF open/render, ML Kit native processing, URI staging, or cleanup—not necessarily Flutter widget disposal.

## Changes made in this PR
- Add a single-flight guard for OCR search and disable the search button while a request is pending.
- Add a monotonically increasing request generation and invalidate it when the screen is disposed. Late completions are ignored.
- Log the complete search exception stack trace through Flutter debug logging.
- Log per-document OCR indexing exceptions with document ID and full stack trace instead of swallowing them.
- Pass a route-disposal cancellation predicate through provider staging, PDF page rendering and ML Kit recognition; stop before starting another page or committing a stale index.
- Close Latin recognizer, Devanagari recognizer and PDF document with nested `finally` blocks so a failure closing one native handle cannot leak the others.
- Keep route-dismissal cancellation separate from genuine OCR failure and restore the prior index status without treating cancellation as a failed document.
- Add widget tests for duplicate search submission and for a search completing after its route is removed.

## Assertion status

The screenshot supplied by the user contains only:

package:flutter/src/widgets/framework.dart: Failed assertion: line 6281 pos 12: '_dependents.isEmpty': is not true.

It does not contain the exception stack trace, preceding logcat lines, Flutter version/runtime mode, or a reproducible action sequence. This assertion alone is insufficient to identify the offending widget or prove OCR is the cause. Do not label this issue fixed until the full stack is captured and the reproduction test demonstrates the fix.

## Required reproduction capture on Android

1. Connect the device with USB debugging enabled.
2. Run: adb logcat -c
3. Reproduce the crash once in DocsGrid.
4. Immediately capture: adb logcat -d -v threadtime > docsgrid-ocr-crash.txt
5. Share the complete file, especially the first Flutter exception and all frames after the framework assertion. Do not trim the log to the red-screen text.

If the log is too large, filter a copy (keep the original):
adb logcat -d -v threadtime | grep -E -i 'flutter|Dart|AndroidRuntime|Exception|dependents|DocsGrid|MLKit|pdfx' > docsgrid-ocr-filtered.txt

## Test matrix still required
- OCR text search with empty, ordinary, percent, underscore, Hindi and long queries.
- Rapid repeated search tap and Enter key.
- Leave the OCR route while the database query is pending.
- Search after indexing and while indexing is active.
- PDF with selectable text, scanned/image-only PDF, multi-page PDF, large PDF, malformed PDF, missing file, revoked SAF URI.
- Android Latin + Devanagari recognizer path and iOS Latin recognizer path.
- Verify recognizers, PDF pages/documents and temporary files are released after success and every failure path.

## Release gate
The Flutter assertion remains under investigation until the user-provided complete device log is correlated with a deterministic test. Hosted CI passing is necessary but not proof of physical-device correctness.