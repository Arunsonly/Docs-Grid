import 'package:docs_grid/core/storage/storage_location_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('read-only recovery picker retains all old source URIs', () {
    final source = StorageLocationService.normalizeRecoverySource({
      'uri': 'content://storage/tree/old',
      'name': 'Previous DocsGrid',
      'rootUri': 'content://storage/tree/old',
      'databaseUri': 'content://storage/tree/old/Database',
      'libraryUri': 'content://storage/tree/old/Folders',
      'documentsUri': 'content://storage/tree/old/Unfiled',
      'recoveryUri': 'content://storage/tree/old/Recovery',
      'backupsUri': 'content://storage/tree/old/Backups',
      'fullBackupsUri': 'content://storage/tree/old/Backups/Full',
      'databaseBackupsUri': 'content://storage/tree/old/Backups/Database',
    });
    expect(source, isNotNull);
    expect(source!['databaseUri'], contains('Database'));
    expect(source['libraryUri'], contains('Folders'));
    expect(source['documentsUri'], contains('Unfiled'));
    expect(source['fullBackupsUri'], contains('Full'));
    expect(source['rootUri'], 'content://storage/tree/old');
  });

  test('invalid or incomplete recovery sources are rejected', () {
    expect(StorageLocationService.normalizeRecoverySource(null), isNull);
    expect(StorageLocationService.normalizeRecoverySource({
      'uri': 'https://untrusted.example/old',
      'databaseUri': 'content://somewhere',
      'libraryUri': 'content://somewhere',
      'documentsUri': 'content://somewhere',
    }), isNull);
    expect(() => StorageLocationService.normalizeRecoverySource({
      'uri': 'content://old',
      'name': 'Old',
    }), throwsStateError);
  });

  test('a native file-backed source can be inspected without selecting it live',
      () {
    final source = StorageLocationService.normalizeRecoverySource({
      'uri': 'file:///storage/emulated/0/Android/media/DocsGrid/',
      'rootUri': 'file:///storage/emulated/0/Android/media/DocsGrid/',
      'databaseUri':
          'file:///storage/emulated/0/Android/media/DocsGrid/Database/',
      'documentsUri':
          'file:///storage/emulated/0/Android/media/DocsGrid/Documents/',
      'libraryUri':
          'file:///storage/emulated/0/Android/media/DocsGrid/Folders/',
    });
    expect(source?['rootUri'], contains('Android/media/DocsGrid'));
  });
}
