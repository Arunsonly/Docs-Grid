import 'dart:typed_data';

import 'package:flutter/services.dart';

class StorageLocationService {
  StorageLocationService._();
  static final StorageLocationService instance = StorageLocationService._();
  static const MethodChannel _channel = MethodChannel('docsgrid/storage');

  Future<Map<String, String>?> selectedFolder() async {
    final value = await _channel.invokeMapMethod<String, dynamic>('getSelectedFolder');
    if (value == null || value['uri'] == null) return null;
    return {'uri': value['uri'] as String, 'name': (value['name'] as String?) ?? 'Selected folder'};
  }

  Future<Map<String, String>?> chooseFolder() async {
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
    if (uri == null) throw StateError('Android did not return the saved PDF location.');
    return uri;
  }

  Future<String> renamePdf({required String uri, required String name}) async {
    final result = await _channel.invokeMethod<String>('renamePdf', {'uri': uri, 'name': name});
    if (result == null) throw StateError('Android did not return the renamed PDF location.');
    return result;
  }

  Future<void> deletePdf(String uri) async {
    final deleted = await _channel.invokeMethod<bool>('deletePdf', {'uri': uri});
    if (deleted != true) throw StateError('Android could not delete the PDF.');
  }

  Future<void> openPdf(String uri) async {
    await _channel.invokeMethod<bool>('openPdf', {'uri': uri});
  }
}
