import 'package:flutter_test/flutter_test.dart';
import 'package:docs_grid/core/storage/pdf_copy_verifier.dart';

void main() {
  group('PdfCopyVerifier', () {
    test('keeps a verified destination', () async {
      var deleted = false;

      await PdfCopyVerifier.verifyOrDeleteOnFailure(
        expectedSha256: 'same-digest',
        readDestinationSha256: () async => 'same-digest',
        deleteDestination: () async { deleted = true; },
      );

      expect(deleted, isFalse);
    });

    test('deletes a destination when its checksum differs', () async {
      var deleted = false;

      await expectLater(
        PdfCopyVerifier.verifyOrDeleteOnFailure(
          expectedSha256: 'source-digest',
          readDestinationSha256: () async => 'different-digest',
          deleteDestination: () async => deleted = true,
        ),
        throwsA(isA<StateError>()),
      );

      expect(deleted, isTrue);
    });

    test('deletes a destination when checksum reading fails', () async {
      var deleted = false;

      await expectLater(
        PdfCopyVerifier.verifyOrDeleteOnFailure(
          expectedSha256: 'source-digest',
          readDestinationSha256: () async => throw StateError('provider read failed'),
          deleteDestination: () async => deleted = true,
        ),
        throwsA(isA<StateError>()),
      );

      expect(deleted, isTrue);
    });

    test('preserves the verification error if cleanup also fails', () async {
      var deleted = false;

      await expectLater(
        PdfCopyVerifier.verifyOrDeleteOnFailure(
          expectedSha256: 'source-digest',
          readDestinationSha256: () async => 'different-digest',
          deleteDestination: () async {
            deleted = true;
            throw StateError('provider delete failed');
          },
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'PDF verification failed; original file was kept.',
          ),
        ),
      );

      expect(deleted, isTrue);
    });
  });
}
