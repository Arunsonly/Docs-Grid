import 'dart:async';

import 'package:flutter/foundation.dart';

import 'storage_location_service.dart';

/// Tracks Android's special all-files access switch across Settings round-trips.
class StorageAccessNotifier {
  StorageAccessNotifier._();

  static final StorageAccessNotifier instance = StorageAccessNotifier._();

  final ValueNotifier<bool?> granted = ValueNotifier<bool?>(null);

  Future<bool> refresh({int attempts = 1}) async {
    final count = attempts < 1 ? 1 : attempts;
    for (var attempt = 0; attempt < count; attempt++) {
      try {
        final value = await StorageLocationService.instance.hasAllFilesAccess();
        granted.value = value;
        if (value) return true;
      } catch (_) {
        // Keep the last known value while a transient platform call is retried.
      }
      if (attempt + 1 < count) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    return granted.value == true;
  }
}
