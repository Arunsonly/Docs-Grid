import 'package:path/path.dart' as p;

import '../../../core/storage/storage_location_service.dart';

/// Moves one Phone-owned PDF to an already-granted Phone directory.
///
/// The Grid database and its files are not involved. A verified destination
/// exists before the original is removed; failure leaves the original intact.
class PhonePdfMoveService {
  const PhonePdfMoveService();

  static String? _localPath(String uri) {
    if (uri.startsWith('/')) return p.normalize(uri);
    final parsed = Uri.tryParse(uri);
    return parsed?.scheme == 'file' ? p.normalize(parsed!.toFilePath()) : null;
  }

  Future<String> move({
    required String sourceUri,
    required String displayName,
    required String destinationFolderUri,
  }) async {
    if (sourceUri.isEmpty || destinationFolderUri.isEmpty ||
        displayName.isEmpty || displayName == '.' || displayName == '..' ||
        p.basename(displayName) != displayName ||
        !displayName.toLowerCase().endsWith('.pdf')) {
      throw ArgumentError('Select a valid PDF and Phone destination folder.');
    }
    // Do not let the new Phone action reach Grid-owned or system trash areas.
    if (StorageLocationService.isRestrictedPhoneMoveDestination(destinationFolderUri)) {
      throw StateError('Choose a Phone folder outside DocsGrid and Recycle Bin.');
    }
    final sourcePath = _localPath(sourceUri);
    final parentPath = _localPath(destinationFolderUri);
    if (sourcePath != null && parentPath != null &&
        p.dirname(sourcePath) == parentPath) {
      throw StateError('This PDF is already in the selected folder.');
    }
    final storage = StorageLocationService.instance;
    final sourceDigest = await storage.sha256Pdf(sourceUri);
    String? destinationUri;
    var verifiedDistinct = false;
    try {
      destinationUri = await storage.copyPdf(
        sourceUri: sourceUri,
        parentUri: destinationFolderUri,
        name: displayName,
      );
      if (await storage.samePhysicalPdf(
        sourceUri: sourceUri, otherUri: destinationUri,
      )) {
        throw StateError(
          'The destination refers to the original PDF. Nothing was deleted.',
        );
      }
      verifiedDistinct = true;
      if (await storage.sha256Pdf(destinationUri) != sourceDigest) {
        throw StateError('The Phone destination failed SHA-256 verification.');
      }
    } catch (_) {
      // Clean up ONLY a proven-independent, newly-created destination.
      // If identity is unknown, never risk deleting the original file.
      if (verifiedDistinct && destinationUri != null) {
        try { await storage.deletePdf(destinationUri); } catch (_) {}
      }
      rethrow;
    }
    try {
      await storage.deletePdf(sourceUri);
    } catch (error) {
      // The provider may have deleted the source before reporting an error.
      // Keep the VERIFIED destination copy in all cases.
      throw StateError(
        'The destination PDF was verified and kept, but Android could not '
        'confirm removal of the Phone original: $error',
      );
    }
    return destinationUri;
  }
}
