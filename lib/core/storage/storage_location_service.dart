import 'dart:io';

import 'package:flutter/services.dart';

class StorageLocationService {
  StorageLocationService._();
  static final StorageLocationService instance = StorageLocationService._();
  static const MethodChannel _channel = MethodChannel('docsgrid/storage');

  /// Converts the native access-check response into a stable, testable shape.
  /// Unknown native values fail closed instead of being treated as available.
  static Map<String, String> normalizeAccessStatus(
    Map<String, dynamic>? value,
  ) {
    const allowedStatuses = {
      'available',
      'not_configured',
      'revoked',
      'unsupported',
    };
    final rawStatus = value?['status'];
    final status = rawStatus is String && allowedStatuses.contains(rawStatus)
        ? rawStatus
        : 'unknown';
    final rawMessage = value?['message'];
    final message = rawMessage is String && rawMessage.isNotEmpty
        ? rawMessage
        : 'Storage access could not be verified.';
    final rawName = value?['name'];
    return {
      'status': status,
      'message': message,
      if (rawName is String && rawName.isNotEmpty) 'name': rawName,
    };
  }

  Future<Map<String, String>> portableDataLocations() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw UnsupportedError('Portable folder storage is not supported on this platform.');
    }
    final value = await _channel.invokeMapMethod<String, dynamic>('getPortableDataLocations');
    if (value == null ||
        value['databaseUri'] is! String ||
        value['recoveryUri'] is! String ||
        value['libraryUri'] is! String) {
      throw StateError('DocsGrid portable data folders are not configured.');
    }
    return {
      'databaseUri': value['databaseUri'] as String,
      'recoveryUri': value['recoveryUri'] as String,
      'libraryUri': value['libraryUri'] as String,
    };
  }

  Future<Map<String, String>?> selectedFolder() async {
    if (!Platform.isAndroid && !Platform.isIOS) return null;
    final value = await _channel.invokeMapMethod<String, dynamic>('getSelectedFolder');
    if (value == null || value['uri'] == null) return null;
    return {'uri': value['uri'] as String, 'name': (value['name'] as String?) ?? 'Selected folder'};
  }

  /// Checks whether the OS still grants access to the saved external folder.
  /// This does not modify the selected folder or any document record.
  Future<Map<String, String>> checkStorageAccess() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return normalizeAccessStatus({
        'status': 'unsupported',
        'message': 'External folder storage is unavailable on this platform.',
      });
    }
    final value = await _channel.invokeMapMethod<String, dynamic>('checkStorageAccess');
    return normalizeAccessStatus(value);
  }

  Future<Map<String, String>?> chooseFolder() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw UnsupportedError('Choosing a storage folder is not supported on this device.');
    }
    final value = await _channel.invokeMapMethod<String, dynamic>('chooseFolder');
    if (value == null || value['uri'] == null) return null;
    return {'uri': value['uri'] as String, 'name': (value['name'] as String?) ?? 'Selected folder'};
  }

  Future<String> savePdf({
    required String treeUri,
    required String name,
    required Uint8List bytes,
  }) async {
    final uri = await _channel.invokeMethod<String>('savePdf', {
      'treeUri': treeUri,
      'name': name,
      'bytes': bytes,
    });
    if (uri == null) throw StateError('The platform did not return the saved PDF location.');
    return uri;
  }

  Future<String> createDirectory({required String parentUri, required String name}) async {
    final result = await _channel.invokeMethod<String>('createDirectory', {
      'parentUri': parentUri,
      'name': name,
    });
    if (result == null) throw StateError('The platform did not return the created folder location.');
    return result;
  }

  Future<String> copyPdf({
    required String sourceUri,
    required String parentUri,
    required String name,
  }) async {
    final result = await _channel.invokeMethod<String>('copyPdf', {
      'sourceUri': sourceUri,
      'parentUri': parentUri,
      'name': name,
    });
    if (result == null) throw StateError('The platform did not return the copied PDF location.');
    return result;
  }

  Future<void> copyPdfToPath({required String sourceUri, required String destinationPath}) async {
    final copied = await _channel.invokeMethod<bool>('copyPdfToPath', {
      'sourceUri': sourceUri,
      'destinationPath': destinationPath,
    });
    if (copied != true) throw StateError('The platform could not copy the PDF into app storage.');
  }

  Future<String> sha256Pdf(String uri) async {
    final result = await _channel.invokeMethod<String>('sha256Pdf', {'uri': uri});
    if (result == null) throw StateError('The platform did not return a PDF checksum.');
    return result;
  }

  Future<Uint8List> readPdf(String uri) async {
    final result = await _channel.invokeMethod<Uint8List>('readPdf', {'uri': uri});
    if (result == null) throw StateError('The platform did not return PDF bytes.');
    return result;
  }

  Future<String> findChildUri({required String parentUri, required String name}) async {
    final result = await _channel.invokeMethod<String>('findChildUri', {
      'parentUri': parentUri,
      'name': name,
    });
    if (result == null) throw StateError('The platform could not resolve a child storage location.');
    return result;
  }

  Future<String?> findChildUriIfExists({
    required String parentUri,
    required String name,
  }) {
    return _channel.invokeMethod<String>('findChildUriIfExists', {
      'parentUri': parentUri,
      'name': name,
    });
  }

  Future<String> renamePdf({required String uri, required String name}) async {
    final result = await _channel.invokeMethod<String>('renamePdf', {'uri': uri, 'name': name});
    if (result == null) throw StateError('The platform did not return the renamed PDF location.');
    return result;
  }

  Future<void> deletePdf(String uri) async {
    final deleted = await _channel.invokeMethod<bool>('deletePdf', {'uri': uri});
    if (deleted != true) throw StateError('The platform could not delete the PDF.');
  }

  Future<void> openPdf(String uri) async {
    await _channel.invokeMethod<bool>('openPdf', {'uri': uri});
  }

  /// Writes a generic UTF-8 metadata file through the platform's granted
  /// folder handle. This intentionally does not use PDF-only storage APIs.
  Future<String> writeTextFile({
    required String parentUri,
    required String name,
    required String contents,
  }) async {
    final result = await _channel.invokeMethod<String>('writeTextFile', {
      'parentUri': parentUri,
      'name': name,
      'contents': contents,
    });
    if (result == null) throw StateError('The platform did not return the metadata file location.');
    return result;
  }

  Future<String> readTextFile(String uri) async {
    final result = await _channel.invokeMethod<String>('readTextFile', {'uri': uri});
    if (result == null) throw StateError('The platform did not return metadata contents.');
    return result;
  }

  /// Enumerates only immediate children. Returned URIs remain opaque platform
  /// handles; callers must never convert them into filesystem paths.
  Future<List<Map<String, Object?>>> listDirectory(String uri) async {
    final result = await _channel.invokeListMethod<dynamic>('listDirectory', {'uri': uri});
    if (result == null) throw StateError('The platform could not list the selected folder.');
    return result.map((entry) {
      if (entry is! Map) throw StateError('The platform returned an invalid directory entry.');
      final item = Map<String, Object?>.from(entry);
      if (item['name'] is! String || item['uri'] is! String || item['isDirectory'] is! bool) {
        throw StateError('The platform returned an incomplete directory entry.');
      }
      return item;
    }).toList(growable: false);
  }
}
