import 'dart:io';

import 'package:flutter/services.dart';

class StorageLocationService {
  StorageLocationService._();
  static final StorageLocationService instance = StorageLocationService._();
  static const MethodChannel _channel = MethodChannel('docsgrid/storage');

  /// Only an explicit native NOT_FOUND result permits creating a provider child.
  /// Permission, provider and I/O failures must propagate without side effects.
  static bool isNotFoundError(Object error) =>
      error is PlatformException && error.code == 'NOT_FOUND';

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

  /// Selects an existing DocsGrid backup tree without creating missing folders.
  /// Android validates Documents/Folders/Database/Recovery and at least one
  /// snapshot before updating the active portable-storage preferences.
  Future<Map<String, String>?> chooseRecoveryFolder() async {
    if (Platform.isAndroid) {
      final value = await _channel.invokeMapMethod<String, dynamic>('chooseRecoveryFolder');
      if (value == null || value['uri'] == null) return null;
      return {'uri': value['uri'] as String, 'name': (value['name'] as String?) ?? 'DocsGrid'};
    }
    return chooseFolder();
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

  /// Recursively discovers PDFs only inside the root the user explicitly
  /// granted through SAF / Files. URIs stay opaque; no guessed filesystem path
  /// or unrestricted device-wide storage scan is attempted.
  Future<List<Map<String, Object?>>> listPdfFilesRecursively(
    String rootUri, {
    int maxEntries = 50000,
    int maxDepth = 64,
    bool includeEmptyFolders = false,
  }) async {
    final pending = <({String uri, String path, int depth})>[
      (uri: rootUri, path: '', depth: 0),
    ];
    final visited = <String>{};
    final pdfs = <Map<String, Object?>>[];
    var visitedEntries = 0;
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!visited.add(current.uri)) continue;
      if (current.depth > maxDepth) {
        throw StateError('The selected folder is nested too deeply to index safely.');
      }
      final children = await listDirectory(current.uri);
      for (final child in children) {
        visitedEntries++;
        if (visitedEntries > maxEntries) {
          throw StateError('The selected folder contains more than $maxEntries entries. Choose a smaller folder.');
        }
        final name = child['name'] as String;
        final uri = child['uri'] as String;
        if (child['isDirectory'] == true) {
          pending.add((
            uri: uri,
            path: current.path.isEmpty ? name : '${current.path}/$name',
            depth: current.depth + 1,
          ));
        } else if (name.toLowerCase().endsWith('.pdf')) {
          pdfs.add(<String, Object?>{
            'name': name,
            'uri': uri,
            'folderPath': current.path,
            'parentUri': current.uri,
          });
        }
      }
    }
    pdfs.sort((a, b) {
      final folder = (a['folderPath'] as String).compareTo(b['folderPath'] as String);
      return folder != 0 ? folder : (a['name'] as String).toLowerCase()
          .compareTo((b['name'] as String).toLowerCase());
    });
    return pdfs;
  }


  /// Lists PDFs and only folders that contain PDFs somewhere below them,
  /// within the explicitly granted SAF root. Empty folder branches are omitted.
  Future<List<Map<String, Object?>>> listStorageTreeRecursively(
    String rootUri, {
    int maxEntries = 50000,
    int maxDepth = 64,
  }) async {
    final pending = <({String uri, String path, int depth})>[
      (uri: rootUri, path: '', depth: 0),
    ];
    final visited = <String>{};
    final entries = <Map<String, Object?>>[];
    final foldersWithPdfs = <String>{};
    final allFolders = <String>{};
    var visitedEntries = 0;
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!visited.add(current.uri)) continue;
      if (current.depth > maxDepth) {
        throw StateError('The selected folder is nested too deeply to browse safely.');
      }
      final children = await listDirectory(current.uri);
      for (final child in children) {
        visitedEntries++;
        if (visitedEntries > maxEntries) {
          throw StateError('The selected folder contains more than $maxEntries entries. Choose a smaller folder.');
        }
        final name = child['name'] as String;
        final uri = child['uri'] as String;
        if (child['isDirectory'] == true) {
          final path = current.path.isEmpty ? name : '${current.path}/$name';
          allFolders.add(path);
          pending.add((uri: uri, path: path, depth: current.depth + 1));
        } else if (name.toLowerCase().endsWith('.pdf')) {
          entries.add(<String, Object?>{
            'name': name, 'uri': uri, 'folderPath': current.path,
            'isDirectory': false,
          });
          var ancestor = current.path;
          while (ancestor.isNotEmpty) {
            foldersWithPdfs.add(ancestor);
            final separator = ancestor.lastIndexOf('/');
            ancestor = separator < 0 ? '' : ancestor.substring(0, separator);
          }
        }
      }
    }
    // Keep only folders on a path to at least one PDF. Root-level PDFs remain
    // visible without creating a synthetic empty-folder row.
    final visibleFolders = includeEmptyFolders ? allFolders : foldersWithPdfs;
    entries.addAll(visibleFolders.map((path) {
      final segments = path.split('/');
      return <String, Object?>{
        'name': segments.last,
        'uri': '',
        'folderPath': segments.length == 1 ? '' : segments.sublist(0, segments.length - 1).join('/'),
        'path': path,
        'isDirectory': true,
      };
    }));
    entries.sort((a, b) {
      final path = (a['folderPath'] as String).compareTo(b['folderPath'] as String);
      if (path != 0) return path;
      if (a['isDirectory'] != b['isDirectory']) return a['isDirectory'] == true ? -1 : 1;
      return (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase());
    });
    return entries;
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
