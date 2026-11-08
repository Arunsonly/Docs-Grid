/// Verifies a copied PDF before callers replace or remove its source.
class PdfCopyVerifier {
  const PdfCopyVerifier._();

  /// Deletes an unverified destination on every verification failure.
  ///
  /// The original source is deliberately outside this helper and must remain
  /// untouched until this method completes successfully.
  static Future<void> verifyOrDeleteOnFailure({
    required String expectedSha256,
    required Future<String> Function() readDestinationSha256,
    required Future<void> Function() deleteDestination,
  }) async {
    try {
      final actualSha256 = await readDestinationSha256();
      if (actualSha256 != expectedSha256) {
        throw StateError('PDF verification failed; original file was kept.');
      }
    } catch (_) {
      try {
        await deleteDestination();
      } catch (_) {
        // Preserve the verification error; the source remains the recovery copy.
      }
      rethrow;
    }
  }
}
