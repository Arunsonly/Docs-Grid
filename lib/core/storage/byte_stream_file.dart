import 'dart:io';

/// Writes a picked provider stream to a temporary file without buffering the
/// complete PDF/ZIP in memory. A failed read never leaves a partial staging
/// file behind.
Future<File> writeByteStreamToFile(
  Stream<List<int>> bytes,
  File destination,
) async {
  final sink = destination.openWrite();
  try {
    await sink.addStream(bytes);
    await sink.flush();
  } catch (_) {
    try {
      await sink.close();
    } catch (_) {
      // Preserve the original stream/write error.
    }
    try {
      if (await destination.exists()) await destination.delete();
    } catch (_) {
      // A cleanup failure must not hide the original failure.
    }
    rethrow;
  }
  await sink.close();
  return destination;
}
