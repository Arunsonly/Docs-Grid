import 'package:docs_grid/core/storage/storage_location_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('legacy DocsGrid recovery prompt policy', () {
    test('clean installation does not show recovery dialog', () {
      expect(StorageLocationService.hasRecoverableLegacyData({
        'status': 'confirmed_no_previous_data',
      }), isFalse);
    });

    test('empty or unverified legacy directory does not show recovery dialog', () {
      expect(StorageLocationService.hasRecoverableLegacyData({
        'status': 'found_folder_without_verified_recoverable_data',
      }), isFalse);
    });

    test('verified legacy PDFs enable the recovery dialog', () {
      expect(StorageLocationService.hasRecoverableLegacyData({
        'status': 'found_recoverable_data',
        'hasPdfs': true,
      }), isTrue);
    });

    test('verified backup or metadata snapshot enables recovery', () {
      expect(StorageLocationService.hasRecoverableLegacyData({
        'status': 'found_recoverable_data',
        'hasBackup': true,
      }), isTrue);
      expect(StorageLocationService.hasRecoverableLegacyData({
        'status': 'found_recoverable_data',
        'hasSnapshot': true,
      }), isTrue);
    });

    test('permission/provider failure is not treated as fresh storage', () {
      expect(StorageLocationService.hasRecoverableLegacyData({
        'status': 'detection_unavailable',
      }), isFalse);
      expect(StorageLocationService.isConfirmedFreshLegacyState({
        'status': 'detection_unavailable',
      }), isFalse);
    });
  });
}
