import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StorageLocationService {
  StorageLocationService._();
  static final StorageLocationService instance = StorageLocationService._();
  static const MethodChannel _channel = MethodChannel('docsgrid/storage');
  static const EventChannel _changesChannel = EventChannel('docsgrid/storage_changes');

  /// Foreground storage change notifications; events contain no file metadata.
  Stream<void> get storageChanges =>
      _changesChannel.receiveBroadcastStream().map<void>((_) {});

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

  /// Recognizes only the former writable DocsGrid roots, not the canonical root.
  static bool isLegacyDocsGridStorageLocation(String? value) {
    if (value == null || value.isEmpty) return false;
    String decoded;
    try { decoded = Uri.decodeComponent(value); } catch (_) { decoded = value; }
    final normalized = decoded.replaceAll('\\', '/').toLowerCase();
    // SAF tree document IDs use the form "primary:Android/media/DocsGrid",
    // so Android's segment may follow a colon rather than a slash.
    return normalized.contains('android/media/docsgrid') ||
        normalized.contains('/docsgrid/pdfs');
  }

  static bool isCanonicalPortableRootUri(String? value) {
    if (value == null || value.isEmpty) return false;
    String decoded;
    try { decoded = Uri.decodeComponent(value); } catch (_) { decoded = value; }
    final normalized = decoded.replaceAll('\\', '/').toLowerCase();
    return normalized.contains('/android/media/com.docsgrid');
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
    final locations = <String, String>{
      'databaseUri': value['databaseUri'] as String,
      'recoveryUri': value['recoveryUri'] as String,
      'libraryUri': value['libraryUri'] as String,
      if (value['documentsUri'] is String)
        'documentsUri': value['documentsUri'] as String,
      if (value['rootUri'] is String) 'rootUri': value['rootUri'] as String,
      if (value['legacyRootUri'] is String) 'legacyRootUri': value['legacyRootUri'] as String,
      if (value['sharedUri'] is String) 'sharedUri': value['sharedUri'] as String,
      if (value['backupsUri'] is String) 'backupsUri': value['backupsUri'] as String,
      if (value['fullBackupsUri'] is String) 'fullBackupsUri': value['fullBackupsUri'] as String,
      if (value['databaseBackupsUri'] is String) 'databaseBackupsUri': value['databaseBackupsUri'] as String,
      if (value['restoreReportsUri'] is String) 'restoreReportsUri': value['restoreReportsUri'] as String,
      if (value['restoreCheckpointsUri'] is String) 'restoreCheckpointsUri': value['restoreCheckpointsUri'] as String,
      if (value['tempUri'] is String) 'tempUri': value['tempUri'] as String,
      if (value['logsUri'] is String) 'logsUri': value['logsUri'] as String,
      if (value['exportsUri'] is String) 'exportsUri': value['exportsUri'] as String,
      if (value['thumbnailsUri'] is String) 'thumbnailsUri': value['thumbnailsUri'] as String,
      if (value['cacheUri'] is String) 'cacheUri': value['cacheUri'] as String,
      if (value['pagePreviewsUri'] is String) 'pagePreviewsUri': value['pagePreviewsUri'] as String,
      if (value['searchIndexUri'] is String) 'searchIndexUri': value['searchIndexUri'] as String,
      if (value['folderIndexUri'] is String) 'folderIndexUri': value['folderIndexUri'] as String,
    };
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('docsgrid_portable_locations_v1', jsonEncode(locations));
    } catch (_) {
      // Background automation may fall back safely when no path cache exists.
    }
    return locations;
  }

  Future<Map<String, String>> cachedPortableDataLocations() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('docsgrid_portable_locations_v1');
    if (raw == null) return const <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, String>{};
      return decoded.map<String, String>((key, value) =>
          MapEntry(key.toString(), value.toString()));
    } catch (_) {
      return const <String, String>{};
    }
  }

  /// Queries the Android MediaStore index over mounted shared-storage volumes.
  Future<Map<String, Object?>> queryPhonePdfIndex() async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('MediaStore indexing is available on Android only.');
    }
    final value = await _channel.invokeMapMethod<String, dynamic>('queryPhonePdfIndex');
    if (value == null) {
      throw StateError('Android did not return a valid MediaStore PDF index.');
    }
    return normalizePhonePdfIndexResponse(value);
  }

  /// Removes the synthetic root labels added by the Phone storage browser.
  /// The result is a true path relative to the storage volume.
  static String normalizePhoneFolderPath(String? value) {
    final segments = (value ?? '')
        .replaceAll('\\', '/')
        .split('/')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.isEmpty) return '';
    final first = segments.first.toLowerCase();
    if (first == 'internal' ||
        first == 'internal storage' ||
        first.startsWith('external storage ') ||
        first.startsWith('granted folder ')) {
      segments.removeAt(0);
    }
    return segments.join('/');
  }

  @visibleForTesting
  static bool isAndroidTrashPath(String? value) {
    if (value == null || value.trim().isEmpty) return false;
    final normalized = value.replaceAll('\\', '/').toLowerCase();
    final segments = normalized.split('/').where((part) => part.isNotEmpty);
    return segments.any((part) =>
        part == '.trash' ||
        part == '.trashed' ||
        part == '.recycle' ||
        part == 'recycle_bin' ||
        part == 'recycle bin');
  }

  /// Normalizes the native MediaStore response separately from the Android
  /// channel guard, so the response contract can be unit-tested on every host.
  @visibleForTesting
  static Map<String, Object?> normalizePhonePdfIndexResponse(
    Map<String, dynamic> value,
  ) {
    if (value['entries'] is! List) {
      throw StateError('Android did not return a valid MediaStore PDF index.');
    }
    final entries = (value['entries'] as List)
        .whereType<Map>()
        .map((entry) => Map<String, Object?>.from(entry))
        .where((entry) => !isAndroidTrashPath(
          entry['folderPath'] as String? ?? entry['path'] as String?,
        ))
        .toList(growable: false);
    final volumes = value['volumes'] is Map
        ? Map<String, Object?>.from(value['volumes'] as Map)
        : <String, Object?>{};
    return {
      'entries': entries,
      'volumes': volumes,
      'complete': value['complete'] == true,
    };
  }

  /// Read-only first-install probe for known DocsGrid-managed Android roots.
  /// Permission failures remain "detection_unavailable", never "no old data".
  static bool hasRecoverableLegacyData(Map<String, Object?> detection) {
    return detection['status'] == 'found_recoverable_data' &&
        (detection['hasPdfs'] == true ||
            detection['hasBackup'] == true ||
            detection['hasSnapshot'] == true);
  }

  static bool isConfirmedFreshLegacyState(Map<String, Object?> detection) {
    return detection['status'] == 'confirmed_no_previous_data' ||
        detection['status'] == 'found_folder_without_verified_recoverable_data';
  }

  Future<bool> isAppUpdateInstall() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('isAppUpdateInstall') ?? false;
  }

  Future<Map<String, Object?>> detectLegacyDocsGridData() async {
    if (!Platform.isAndroid) {
      return const <String, Object?>{'status': 'confirmed_no_previous_data'};
    }
    final value = await _channel.invokeMapMethod<String, dynamic>(
      'detectLegacyDocsGridData',
    );
    if (value == null) {
      return const <String, Object?>{'status': 'detection_unavailable'};
    }
    final status = value['status'];
    const allowed = {
      'found_recoverable_data',
      'confirmed_no_previous_data',
      'detection_unavailable',
      'found_folder_without_verified_recoverable_data',
    };
    return <String, Object?>{
      'status': status is String && allowed.contains(status)
          ? status
          : 'detection_unavailable',
      'hasPdfs': value['hasPdfs'] == true,
      'hasBackup': value['hasBackup'] == true,
      'hasSnapshot': value['hasSnapshot'] == true,
      'legacyRoots': value['legacyRoots'] is List
          ? List<String>.from(value['legacyRoots'] as List)
          : const <String>[],
    };
  }

  Future<bool> hasAllFilesAccess() async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
  }

  /// Actual primary shared-storage occupancy reported by Android StatFs.
  Future<Map<String, int>> phoneStorageUsage() async {
    final value = await _channel.invokeMapMethod<String, dynamic>('getStorageUsage');
    if (value == null || value['usedBytes'] is! num ||
        value['totalBytes'] is! num || value['availableBytes'] is! num) {
      throw StateError('Android did not return valid phone storage usage.');
    }
    return {
      'usedBytes': (value['usedBytes'] as num).toInt(),
      'totalBytes': (value['totalBytes'] as num).toInt(),
      'availableBytes': (value['availableBytes'] as num).toInt(),
    };
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
  @visibleForTesting
  static List<Map<String, String>> normalizeAccessibleStorageRoots(
    Iterable<dynamic> values,
  ) {
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

  Future<List<Map<String, String>>> accessibleStorageRoots() async {
    if (!Platform.isAndroid) return const [];
    final values = await _channel.invokeListMethod<dynamic>('getAccessibleScanRoots') ?? const [];
    return normalizeAccessibleStorageRoots(values);
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
    // Older restored folder records may still contain a bare absolute
    // filesystem path instead of a URI. Normalize at the storage boundary so
    // every PDF-import caller (Grid folder import, WhatsApp share, scanner,
    // move/copy) sends a valid file:// URI to Android.
    final normalizedParentUri = Platform.isAndroid && parentUri.startsWith('/')
        ? Uri.file(parentUri).toString()
        : parentUri;
    final result = await _channel.invokeMethod<String>('copyPdf', {
      'sourceUri': sourceUri,
      'parentUri': normalizedParentUri,
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
  /// Publishes a private staged file into a user-selected shared folder.
  /// Android streams and SHA-256 verifies the copy before the final name appears.
  Future<String> copyFileToStorage({
    required String sourcePath,
    required String parentUri,
    required String name,
    String mimeType = 'application/octet-stream',
  }) async {
    final result = await _channel.invokeMethod<String>('copyFileToStorage', {
      'sourcePath': sourcePath,
      'parentUri': parentUri,
      'name': name,
      'mimeType': mimeType,
    });
    if (result == null) {
      throw StateError('The platform did not return the published file location.');
    }
    return result;
  }

  /// Stages a selected provider file into app-private storage and verifies
  /// its digest before Dart can parse or restore it.
  Future<void> copyStorageFileToPath({
    required String sourceUri,
    required String destinationPath,
  }) async {
    final copied = await _channel.invokeMethod<bool>('copyStorageFileToPath', {
      'sourceUri': sourceUri,
      'destinationPath': destinationPath,
    });
    if (copied != true) {
      throw StateError('The selected storage file could not be staged safely.');
    }
  }

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
          final path = current.path.isEmpty ? name : '${current.path}/$name';
          if (isExcludedStorageDirectoryPath(path)) continue;
          pending.add((
            uri: uri,
            path: path,
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


  /// System trash folders are not part of the user's document library.
  /// Android vendors (including Samsung My Files) expose these as hidden
  /// ".Trash" directories; never recurse into them or surface their PDFs.
  @visibleForTesting
  static bool isExcludedStorageDirectoryPath(String path) =>
      isAndroidTrashPath(path);

  /// Lists PDFs and only folders that contain PDFs somewhere below them,
  /// within the explicitly granted SAF root. Empty folder branches are omitted.
  Future<List<Map<String, Object?>>> listStorageTreeRecursively(
    String rootUri, {int maxEntries = 50000, int maxDepth = 64,
    bool includeEmptyFolders = false, String rootLabel = ''}) async {
    final pending = <({String uri, String path, int depth})>[
      (uri: rootUri, path: '', depth: 0),
    ];
    final visited = <String>{};
    final entries = <Map<String, Object?>>[];
    final counts = <String, int>{}, sizes = <String, int>{}, unknownSizes = <String, int>{};
    final withPdfs = <String>{}, allFolders = <String>{}, inaccessible = <String>[];
    final incompleteFolders = <String>{};
    var visitedEntries = 0;

    // SAF providers can be slow. Read a bounded batch of directories in
    // parallel instead of making one platform-channel round trip at a time.
    const scanConcurrency = 4;
    while (pending.isNotEmpty) {
      final batch = <({String uri, String path, int depth})>[];
      while (pending.isNotEmpty && batch.length < scanConcurrency) {
        final current = pending.removeLast();
        if (visited.add(current.uri)) {
          if (current.depth > maxDepth) {
            throw StateError('Storage is nested too deeply to scan safely.');
          }
          batch.add(current);
        }
      }
      if (batch.isEmpty) continue;

      final readErrors = <String, Object>{};
      final childLists = await Future.wait(batch.map((current) async {
        try {
          return await listDirectory(current.uri);
        } catch (error) {
          readErrors[current.uri] = error;
          return null;
        }
      }));

      for (var batchIndex = 0; batchIndex < batch.length; batchIndex++) {
        final current = batch[batchIndex];
        final children = childLists[batchIndex];
        if (children == null) {
          final error = readErrors[current.uri]!;
          if (current.depth == 0) throw error;
          inaccessible.add(current.path);
          var incompletePath = current.path;
          while (incompletePath.isNotEmpty) {
            incompleteFolders.add(incompletePath);
            final slash = incompletePath.lastIndexOf('/');
            incompletePath = slash < 0 ? '' : incompletePath.substring(0, slash);
          }
          entries.add({
            'name': current.path.split('/').last,
            'uri': current.uri,
            'folderPath': current.path.contains('/')
                ? current.path.substring(0, current.path.lastIndexOf('/'))
                : '',
            'path': current.path,
            'isDirectory': true,
            'isInaccessible': true,
            'accessError': error.toString(),
          });
          continue;
        }

        for (final child in children) {
          if (++visitedEntries > maxEntries) {
            throw StateError('Storage exceeds $maxEntries entries; scan stopped safely.');
          }
          final name = child['name'] as String;
          final uri = child['uri'] as String;
          if (child['isDirectory'] == true) {
            final path = current.path.isEmpty ? name : '${current.path}/$name';
            if (isExcludedStorageDirectoryPath(path)) continue;
            allFolders.add(path);
            if (path == 'Android/media/com.docsgrid' ||
                path.startsWith('Android/media/com.docsgrid/')) {
              continue;
            }
            pending.add((uri: uri, path: path, depth: current.depth + 1));
          } else if (name.toLowerCase().endsWith('.pdf')) {
            final size = (child['sizeBytes'] as num?)?.toInt() ??
                (child['size'] as num?)?.toInt() ?? 0;
            final sizeKnown = child['sizeKnown'] as bool? ?? true;
            entries.add({
              'name': name,
              'uri': uri,
              'folderPath': current.path,
              'sizeBytes': size < 0 ? 0 : size,
              'sizeKnown': sizeKnown,
              'lastModified': child['lastModified'],
              'isDirectory': false,
            });
            // Only mark the folder that directly contains this PDF.
            if (current.path.isNotEmpty) {
              withPdfs.add(current.path);
              counts[current.path] = (counts[current.path] ?? 0) + 1;
              sizes[current.path] = (sizes[current.path] ?? 0) + (size < 0 ? 0 : size);
              if (!sizeKnown) {
                unknownSizes[current.path] = (unknownSizes[current.path] ?? 0) + 1;
              }
            }
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
          final folder=entry['folderPath'] as String? ?? '';
          // The virtual Internal folder represents root-level PDFs only.
          if (folder.isEmpty) {
            totalCount++;
            totalBytes+=(entry['sizeBytes'] as num?)?.toInt() ?? 0;
            if (entry['sizeKnown'] == false) totalUnknownSizes++;
          }
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
