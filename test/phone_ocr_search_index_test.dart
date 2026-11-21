import 'package:docs_grid/features/documents/data/phone_ocr_search_index.dart';
import 'package:docs_grid/features/tools/document_tools_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const pdfs = <Map<String, Object?>>[
    {
      'uri': 'content://phone/a',
      'name': 'Document_1.pdf',
      'sizeBytes': 100,
      'lastModified': 123,
    },
    {
      'uri': 'content://phone/b',
      'name': '2026.pdf',
      'sizeBytes': 200,
      'lastModified': 123,
    },
    {
      'uri': 'content://phone/folder',
      'name': 'Work',
      'isDirectory': true,
    },
  ];

  test('Phone search indexes PDF content only after explicit request', () async {
    final calls = <String>[];
    final index = PhoneOcrSearchIndex((uri, {shouldCancel}) async {
      calls.add(uri);
      return uri.endsWith('/a')
          ? 'Policy holder Arun reference 982731'
          : 'Other independent content';
    });
    expect(index.matches(pdfs, '982731'), isEmpty);
    expect(calls, isEmpty, reason: 'Ordinary filename search never reads PDF bytes.');
    final result = await index.indexEntries(pdfs);
    expect(result.completed, 2);
    expect(result.failed, 0);
    expect(calls, ['content://phone/a', 'content://phone/b']);
    expect(index.matches(pdfs, '982731').map((e) => e['name']),
        ['Document_1.pdf']);
    expect(index.matches(pdfs, 'arun').map((e) => e['name']),
        ['Document_1.pdf']);
    expect(index.matches(pdfs, 'document_1'), isEmpty,
        reason: 'OCR mode matches PDF content, not filenames.');
    await index.indexEntries(pdfs);
    expect(calls, hasLength(2), reason: 'No rescan for a new query.');
    index.clear();
    expect(index.matches(pdfs, '982731'), isEmpty);
  });

  test('changed PDF is reindexed; unavailable Phone PDF does not block others',
      () async {
    final calls = <String>[];
    final index = PhoneOcrSearchIndex((uri, {shouldCancel}) async {
      calls.add(uri);
      if (uri.endsWith('/a')) throw StateError('Missing permission');
      return 'Found policy 1234';
    });
    final summary = await index.indexEntries(pdfs);
    expect(summary.failed, 1);
    expect(index.matches(pdfs, '1234').map((e) => e['name']),
        ['2026.pdf']);
    expect(calls, hasLength(2));
    await index.indexEntries(pdfs);
    expect(calls, hasLength(2));
    final changed = [
      {...pdfs[0], 'lastModified': 456},
      pdfs[1],
    ];
    await index.indexEntries(changed);
    expect(calls, hasLength(3));
  });

  test('cancellation interrupts Phone OCR before the next PDF', () async {
    final calls = <String>[];
    var canceled = false;
    final index = PhoneOcrSearchIndex((uri, {shouldCancel}) async {
      calls.add(uri);
      return 'contains policy';
    });
    await expectLater(
      index.indexEntries(pdfs,
        shouldCancel: () => canceled,
        onProgress: (_, __) => canceled = true,
      ),
      throwsA(isA<OcrIndexCancelled>()),
    );
    expect(calls, ['content://phone/a']);
    expect(index.matches(pdfs, 'policy'), hasLength(1));
    index.clear();
    expect(index.matches(pdfs, 'policy'), isEmpty);
  });
}
