import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Explicit list sorting in Phone and Grid Storage. Defaults match the
/// existing alphabetical Phone browser; Grid retains manually ordered folders
/// until the user explicitly chooses a sort.
enum StorageSortField { name, date }

/// Compare library items without mutating their underlying repository order.
///
/// An absent modification date always sorts after dated items, whether the
/// requested order is ascending or descending. Names are case-insensitive.
int compareStorageItems({
  required String nameA,
  required String nameB,
  DateTime? dateA,
  DateTime? dateB,
  required StorageSortField field,
  required bool ascending,
}) {
  if (field == StorageSortField.date) {
    if (dateA == null && dateB != null) return 1;
    if (dateB == null && dateA != null) return -1;
    if (dateA != null && dateB != null) {
      final chronological = dateA.compareTo(dateB);
      if (chronological != 0) return ascending ? chronological : -chronological;
    }
  }
  final alphabetical = nameA.toLowerCase().compareTo(nameB.toLowerCase());
  return ascending ? alphabetical : -alphabetical;
}

/// The filter button chooses Name/Date, while the adjacent arrow independently
/// controls ascending/descending order. These controls change only list order.
class StorageSortControls extends StatelessWidget {
  const StorageSortControls({
    super.key,
    required this.field,
    required this.ascending,
    required this.onFieldChanged,
    required this.onAscendingChanged,
    this.enabled = true,
  });

  final StorageSortField field;
  final bool ascending;
  final ValueChanged<StorageSortField> onFieldChanged;
  final ValueChanged<bool> onAscendingChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<StorageSortField>(
          key: const ValueKey('storage-sort-filter'),
          tooltip: 'Sort by Name or Date',
          enabled: enabled,
          icon: const Icon(Icons.filter_list),
          onSelected: onFieldChanged,
          itemBuilder: (context) => [
            for (final option in StorageSortField.values)
              PopupMenuItem<StorageSortField>(
                value: option,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(option == StorageSortField.name ? 'Name' : 'Date'),
                    const SizedBox(width: 24),
                    if (field == option)
                      Icon(Icons.check, color: Theme.of(context).colorScheme.primary),
                  ],
                ),
              ),
          ],
        ),
        IconButton(
          key: const ValueKey('storage-sort-direction'),
          tooltip: ascending ? 'Ascending order' : 'Descending order',
          onPressed: enabled ? () => onAscendingChanged(!ascending) : null,
          icon: Icon(ascending ? Icons.arrow_upward : Icons.arrow_downward),
        ),
      ],
    );
  }
}


/// Saved independently for Phone Storage and Grid Storage. A single JSON
/// preference prevents field and direction from being restored out of sync.
class StorageSortPreference {
  const StorageSortPreference._();

  static const phoneKey = 'docsgrid_phone_sort_preference_v1';
  static const gridKey = 'docsgrid_grid_sort_preference_v1';
  static final Map<String, Future<void>> _pending = <String, Future<void>>{};

  static Future<StorageSortSelection?> load(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) return null;
      final value = jsonDecode(raw);
      if (value is! Map) return null;
      final field = switch (value['field']) {
        'name' => StorageSortField.name,
        'date' => StorageSortField.date,
        _ => null,
      };
      if (field == null ||
          value['ascending'] is! bool ||
          value['explicit'] is! bool) return null;
      return StorageSortSelection(
        field: field,
        ascending: value['ascending'] as bool,
        explicit: value['explicit'] as bool,
      );
    } catch (_) {
      // Unknown/corrupt legacy settings retain the existing screen default.
      return null;
    }
  }

  static Future<void> save(
    String key, {
    required StorageSortField field,
    required bool ascending,
    required bool explicit,
  }) {
    final encoded = jsonEncode({
      'field': field.name,
      'ascending': ascending,
      'explicit': explicit,
    });
    final previous = _pending[key] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(key, encoded)) {
        throw StateError('Could not save storage sort preference.');
      }
    });
    _pending[key] = next;
    return next;
  }
}

class StorageSortSelection {
  const StorageSortSelection({
    required this.field,
    required this.ascending,
    required this.explicit,
  });

  final StorageSortField field;
  final bool ascending;
  final bool explicit;
}
