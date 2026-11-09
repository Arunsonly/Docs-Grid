import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Resource limits for untrusted portable backup ZIPs.
/// The ZIP payload is decoded from an InputFileStream and PDF entries are
/// written to staging files; JSON metadata is materialized only after these
/// compressed/expanded size limits have been checked.
class BackupArchiveLimits {
  BackupArchiveLimits._();

  static const maxArchiveBytes = 128 * 1024 * 1024;
  static const maxExpandedBytes = 256 * 1024 * 1024;
  static const maxEntryBytes = 128 * 1024 * 1024;
  static const maxEntries = 10000;
  static const maxCentralDirectoryBytes = 8 * 1024 * 1024;
  static const maxCompressionRatio = 1000;

  static Future<void> validate(File file) async {
    final handle = await file.open(mode: FileMode.read);
    try {
      final fileLength = await handle.length();
      if (fileLength < 22 || fileLength > maxArchiveBytes) {
        throw StateError('Backup archive exceeds the supported compressed size limit.');
      }

      final tailLength = fileLength < 65557 ? fileLength : 65557;
      await handle.setPosition(fileLength - tailLength);
      final tail = await handle.read(tailLength);
      final tailData = ByteData.sublistView(tail);
      var eocd = -1;
      for (var offset = tail.length - 22; offset >= 0; offset--) {
        if (tailData.getUint32(offset, Endian.little) != 0x06054b50) continue;
        final commentLength = tailData.getUint16(offset + 20, Endian.little);
        if (offset + 22 + commentLength == tail.length) {
          eocd = offset;
          break;
        }
      }
      if (eocd < 0) throw StateError('Backup ZIP directory is missing or invalid.');

      final diskNumber = tailData.getUint16(eocd + 4, Endian.little);
      final directoryDisk = tailData.getUint16(eocd + 6, Endian.little);
      final entriesOnDisk = tailData.getUint16(eocd + 8, Endian.little);
      final entryCount = tailData.getUint16(eocd + 10, Endian.little);
      final directorySize = tailData.getUint32(eocd + 12, Endian.little);
      final directoryOffset = tailData.getUint32(eocd + 16, Endian.little);
      final eocdAbsolute = fileLength - tailLength + eocd;

      if (diskNumber != 0 || directoryDisk != 0 || entriesOnDisk != entryCount ||
          entryCount == 0xffff || directorySize == 0xffffffff ||
          directoryOffset == 0xffffffff) {
        throw StateError('Multi-disk and ZIP64 backups are not supported.');
      }
      if (entryCount == 0 || entryCount > maxEntries ||
          directorySize == 0 || directorySize > maxCentralDirectoryBytes ||
          directoryOffset + directorySize > eocdAbsolute) {
        throw StateError('Backup ZIP directory exceeds supported limits.');
      }

      await handle.setPosition(directoryOffset);
      final directory = await handle.read(directorySize);
      if (directory.length != directorySize) {
        throw StateError('Backup ZIP directory is truncated.');
      }
      final data = ByteData.sublistView(directory);
      var offset = 0;
      var expandedTotal = 0;
      final backslash = String.fromCharCode(92);
      final names = <String>{};

      for (var index = 0; index < entryCount; index++) {
        if (offset + 46 > directory.length ||
            data.getUint32(offset, Endian.little) != 0x02014b50) {
          throw StateError('Backup ZIP contains an invalid directory entry.');
        }
        final flags = data.getUint16(offset + 8, Endian.little);
        final compressedSize = data.getUint32(offset + 20, Endian.little);
        final expandedSize = data.getUint32(offset + 24, Endian.little);
        final nameLength = data.getUint16(offset + 28, Endian.little);
        final extraLength = data.getUint16(offset + 30, Endian.little);
        final commentLength = data.getUint16(offset + 32, Endian.little);
        final diskStart = data.getUint16(offset + 34, Endian.little);
        final localHeaderOffset = data.getUint32(offset + 42, Endian.little);
        final entryEnd = offset + 46 + nameLength + extraLength + commentLength;

        if (entryEnd > directory.length || nameLength == 0 ||
            compressedSize == 0xffffffff || expandedSize == 0xffffffff ||
            diskStart != 0 || localHeaderOffset >= directoryOffset ||
            (flags & 0x0001) != 0) {
          throw StateError('Backup ZIP contains an unsupported or unsafe entry.');
        }
        final nameBytes = directory.sublist(offset + 46, offset + 46 + nameLength);
        final name = utf8.decode(nameBytes, allowMalformed: false);
        if (name.startsWith('/') || name.startsWith(backslash) ||
            name.contains(backslash) ||
            name.split('/').any((segment) => segment == '..' || segment.isEmpty) ||
            RegExp(r'^[A-Za-z]:').hasMatch(name) ||
            !names.add(name)) {
          throw StateError('Backup ZIP contains an unsafe or duplicate entry name.');
        }
        if (expandedSize > maxEntryBytes ||
            (expandedSize > 0 && (compressedSize == 0 ||
                expandedSize / compressedSize > maxCompressionRatio))) {
          throw StateError('Backup ZIP contains an entry with an unsafe expansion size.');
        }
        expandedTotal += expandedSize;
        if (expandedTotal > maxExpandedBytes) {
          throw StateError('Backup ZIP expands beyond the supported total size limit.');
        }
        offset = entryEnd;
      }
      if (offset != directory.length) {
        throw StateError('Backup ZIP directory contains trailing or malformed data.');
      }
    } on FormatException {
      throw StateError('Backup ZIP contains an invalid entry name.');
    } finally {
      await handle.close();
    }
  }
}
