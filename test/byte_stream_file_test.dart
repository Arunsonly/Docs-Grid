import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:docs_grid/core/storage/byte_stream_file.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('docsgrid_stream_test_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('stages a large multi-chunk provider stream without changing bytes', () async {
    const chunkSize = 64 * 1024;
    const chunkCount = 384; // 24 MiB; deliberately larger than a small PDF.
    final chunks = List<Uint8List>.generate(
      chunkCount,
      (index) => Uint8List.fromList(
        List<int>.generate(chunkSize, (offset) => (index + offset) & 0xff),
      ),
      growable: false,
    );
    final expected = sha256.convert(chunks.expand((chunk) => chunk)).toString();
    final target = File('${temp.path}/large-provider.pdf');

    await writeByteStreamToFile(Stream<List<int>>.fromIterable(chunks), target);

    expect(await target.length(), chunkSize * chunkCount);
    expect(await sha256.bind(target.openRead()).first, expected);
  });

  test('removes a partial staging file when provider stream fails', () async {
    final target = File('${temp.path}/interrupted-provider.pdf');
    final stream = Stream<List<int>>.multi((controller) {
      controller.add([37, 80, 68, 70]);
      controller.addError(StateError('provider read interrupted'));
    });

    await expectLater(
      writeByteStreamToFile(stream, target),
      throwsA(isA<StateError>()),
    );
    expect(await target.exists(), isFalse);
  });
}
