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
}
