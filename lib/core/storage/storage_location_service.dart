import 'dart:io';

import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

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
      if (value['documentsUri'] is String)
        'documentsUri': value['documentsUri'] as String,
      if (value['rootUri'] is String) 'rootUri': value['rootUri'] as String,
      if (value['legacyRootUri'] is String) 'legacyRootUri': value['legacyRootUri'] as String,
      if (value['sharedUri'] is String) 'sharedUri': value['sharedUri'] as String,
      if (value['backupsUri'] is String) 'backupsUri': value['backupsUri'] as String,
      if (value['tempUri'] is String) 'tempUri': value['tempUri'] as String,
      if (value['logsUri'] is String) 'logsUri': value['logsUri'] as String,
      if (value['exportsUri'] is String) 'exportsUri': value['exportsUri'] as String,
      if (value['thumbnailsUri'] is String) 'thumbnailsUri': value['thumbnailsUri'] as String,
    };
  }

  Future<bool> hasAllFilesAccess() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
  }

  /// Returns an empty map when Android's optional all-files permission is not granted.
  /// This lets ordinary imports and folder operations retain their SAF/private fallback.
  /// Other platform/storage errors still propagate and are not silently hidden.
  Future<Map<String, String>> portableDataLocationsIfAvailable() async {
    if (Platform.isAndroid && !await hasAllFilesAccess()) {
      // A previously selected SAF recovery tree is valid without all-files
      // access. Only fall back when the native layer reports that no
      // accessible portable tree exists because the special permission is off.
      try {
        return await portableDataLocations();
      } on PlatformException catch (error) {
        if (error.code == 'STORAGE_ERROR' &&
            (error.message ?? '').contains('Allow Full internal storage access')) {
          return const <String, String>{};
        }
        rethrow;
      }
    }
    return portableDataLocations();
  }

  /// Opens Android's special app-specific all-files access settings page.
  /// The user must explicitly enable the switch and return to DocsGrid.
  Future<bool> requestAllFilesAccess() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('All-files access is available only on Android.');
    }
    return await _channel.invokeMethod<bool>('requestAllFilesAccess') ?? false;
  }

  Future<Map<String, String>?> selectedFolder() async {
    if (!Platform.isAndroid && !Platform.isIOS) return null;
    final value = await _channel.invokeMapMethod<String, dynamic>('getSelectedFolder');
    if (value == null || value['uri'] == null) return null;
    return {'uri': value['uri'] as String, 'name': (value['name'] as String?) ?? 'Selected folder'};
  }

  /// OS-exposed shared storage and all persisted SAF read grants. No picker.
  Future<List<Map<String, String>>> accessibleStorageRoots() async {
    if (!Platform.isAndroid) return const [];
    final values = await _channel.invokeListMethod<dynamic>('getAccessibleScanRoots') ?? const [];
    final roots = <Map<String, String>>[];
    final seen = <String>{};
    for (final value in values) {
      if (value is! Map) continue;
      final uri = value['uri'], name = value['name'];
      if (uri is! String || uri.isEmpty || !seen.add(uri)) continue;
      roots.add({'uri': uri, 'name': name is String && name.isNotEmpty ? name : 'Granted folder'});
    }
    return roots;
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
    if (!Platform.isAndroid) {
      throw UnsupportedError('Selecting an existing portable recovery tree is currently supported on Android only. Existing data has not been changed.');
    }
    final value = await _channel.invokeMapMethod<String, dynamic>('chooseRecoveryFolder');
    if (value == null || value['uri'] == null) return null;
    return {'uri': value['uri'] as String, 'name': (value['name'] as String?) ?? 'DocsGrid'};
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
    if (uri.startsWith('file://')) {
      final result = await OpenFilex.open(
        Uri.parse(uri).toFilePath(),
        type: 'application/pdf',
      );
      if (result.type != ResultType.done) {
        throw StateError(result.message.isEmpty
            ? 'No PDF viewer is available.'
            : result.message);
      }
      return;
    }
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
            'sizeBytes': (child['size'] as num?)?.toInt() ?? 0,
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
    String rootUri, {int maxEntries = 50000, int maxDepth = 64,
    bool includeEmptyFolders = false, String rootLabel = ''}) async {
    final pending = <({String uri, String path, int depth})>[(uri: rootUri, path: '', depth: 0)];
    final visited = <String>{};
    final entries = <Map<String, Object?>>[];
    final counts = <String, int>{}, sizes = <String, int>{}, unknownSizes = <String, int>{};
    final withPdfs = <String>{}, allFolders = <String>{}, inaccessible = <String>[];
    final incompleteFolders = <String>{};
    var visitedEntries = 0;
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!visited.add(current.uri)) continue;
      if (current.depth > maxDepth) throw StateError('Storage is nested too deeply to scan safely.');
      List<Map<String, Object?>> children;
      try { children = await listDirectory(current.uri); }
      catch (error) {
        if (current.depth == 0) rethrow;
        inaccessible.add(current.path);
        var incompletePath = current.path;
        while (incompletePath.isNotEmpty) {
          incompleteFolders.add(incompletePath);
          final slash = incompletePath.lastIndexOf('/');
          incompletePath = slash < 0 ? '' : incompletePath.substring(0, slash);
        }
        entries.add({'name': current.path.split('/').last, 'uri': current.uri,
          'folderPath': current.path.contains('/') ? current.path.substring(0,current.path.lastIndexOf('/')) : '',
          'path': current.path, 'isDirectory': true, 'isInaccessible': true, 'accessError': error.toString()});
        continue;
      }
      for (final child in children) {
        if (++visitedEntries > maxEntries) throw StateError('Storage exceeds $maxEntries entries; scan stopped safely.');
        final name = child['name'] as String, uri = child['uri'] as String;
        if (child['isDirectory'] == true) {
          final path = current.path.isEmpty ? name : '${current.path}/$name';
          allFolders.add(path);
          if (path == 'Android/media/com.docsgrid' || path.startsWith('Android/media/com.docsgrid/')) continue;
          pending.add((uri: uri, path: path, depth: current.depth + 1));
        } else if (name.toLowerCase().endsWith('.pdf')) {
          final size = (child['sizeBytes'] as num?)?.toInt() ?? (child['size'] as num?)?.toInt() ?? 0;
          final sizeKnown = child['sizeKnown'] as bool? ?? true;
          entries.add({'name': name, 'uri': uri, 'folderPath': current.path,
            'sizeBytes': size < 0 ? 0 : size, 'sizeKnown': sizeKnown, 'isDirectory': false});
          var ancestor = current.path;
          while (ancestor.isNotEmpty) {
            withPdfs.add(ancestor); counts[ancestor] = (counts[ancestor] ?? 0) + 1;
            sizes[ancestor] = (sizes[ancestor] ?? 0) + (size < 0 ? 0 : size);
            if (!sizeKnown) unknownSizes[ancestor] = (unknownSizes[ancestor] ?? 0) + 1;
            final slash = ancestor.lastIndexOf('/'); ancestor = slash < 0 ? '' : ancestor.substring(0,slash);
          }
        }
      }
    }
    final folders = includeEmptyFolders ? allFolders : withPdfs;
    entries.addAll(folders.map((path) {
      final parts = path.split('/');
      return <String,Object?>{'name':parts.last,'uri':'',
        'folderPath':parts.length == 1 ? '' : parts.sublist(0,parts.length-1).join('/'),
        'path':path,'isDirectory':true,'pdfCount':counts[path] ?? 0,'sizeBytes':sizes[path] ?? 0,
        'isIncomplete':incompleteFolders.contains(path),
        'unknownSizeCount':unknownSizes[path] ?? 0,
        'isSizeIncomplete':(unknownSizes[path] ?? 0) > 0 || incompleteFolders.contains(path)};
    }));
    entries.sort((a,b) {
      final pth=(a['folderPath'] as String).compareTo(b['folderPath'] as String);
      if(pth!=0)return pth;
      if(a['isDirectory']!=b['isDirectory'])return a['isDirectory']==true?-1:1;
      return (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase());
    });
    if(rootLabel.isNotEmpty) {
      var totalCount=0,totalBytes=0,totalUnknownSizes=0;
      for(final entry in entries) {
        if(entry['isDirectory']!=true) {
          totalCount++; totalBytes+=(entry['sizeBytes'] as num?)?.toInt() ?? 0;
          if (entry['sizeKnown'] == false) totalUnknownSizes++;
          final folder=entry['folderPath'] as String? ?? '';
          entry['folderPath']=folder.isEmpty?rootLabel:'$rootLabel/$folder';
        } else {
          final path=entry['path'] as String? ?? '';
          if(path.isNotEmpty) {
            entry['path']='$rootLabel/$path';
            entry['folderPath']=path.contains('/')?'$rootLabel/${path.substring(0,path.lastIndexOf('/'))}':rootLabel;
          }
        }
      }
      if (totalCount > 0) {
        entries.add({'name':rootLabel,'uri':rootUri,'folderPath':'','path':rootLabel,
          'isDirectory':true,'pdfCount':totalCount,'sizeBytes':totalBytes,
          'isIncomplete':inaccessible.isNotEmpty,
          'unknownSizeCount':totalUnknownSizes,
          'isSizeIncomplete':inaccessible.isNotEmpty || totalUnknownSizes > 0});
      }
    }
    if(inaccessible.isNotEmpty) entries.add({'name':'${inaccessible.length} inaccessible folder(s)',
      'uri':'','folderPath':'','isDirectory':true,'isInaccessibleSummary':true,'inaccessibleCount':inaccessible.length});
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
