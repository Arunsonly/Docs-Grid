/// Validates untrusted folder metadata before restore code builds paths.
class BackupFolderGraphValidator {
  const BackupFolderGraphValidator._();

  static void validate(List<Map<String, Object?>> folders) {
    final parents = <String, String?>{};
    for (final folder in folders) {
      final id = folder['id'];
      final parentId = folder['parent_id'];
      if (id is! String || id.trim().isEmpty ||
          (parentId != null && parentId is! String) ||
          parents.containsKey(id)) {
        throw StateError('Backup contains an invalid or duplicate folder ID.');
      }
      parents[id] = parentId as String?;
    }

    final visited = <String>{};
    for (final id in parents.keys) {
      final chain = <String>{};
      String? current = id;
      while (current != null && !visited.contains(current)) {
        if (!chain.add(current)) {
          throw StateError('Backup folder hierarchy contains a cycle.');
        }
        final parentId = parents[current];
        if (parentId != null && !parents.containsKey(parentId)) {
          throw StateError('Backup folder hierarchy refers to a missing parent.');
        }
        current = parentId;
      }
      visited.addAll(chain);
    }
  }

  /// Returns folders in stable parent-before-child order for FK-safe inserts.
  static List<Map<String, Object?>> parentFirst(
    List<Map<String, Object?>> folders,
  ) {
    validate(folders);
    final children = <String?, List<Map<String, Object?>>>{};
    for (final folder in folders) {
      children.putIfAbsent(folder['parent_id'] as String?, () => []).add(folder);
    }
    final ordered = <Map<String, Object?>>[];
    final queue = List<Map<String, Object?>>.from(children[null] ?? const []);
    var index = 0;
    while (index < queue.length) {
      final folder = queue[index++];
      ordered.add(folder);
      final id = folder['id'] as String;
      queue.addAll(children[id] ?? const []);
    }
    if (ordered.length != folders.length) {
      throw StateError('Backup folder hierarchy contains a cycle.');
    }
    return List.unmodifiable(ordered);
  }

  /// Returns folders in child-before-parent order for RESTRICT foreign keys.
  static List<Map<String, Object?>> childFirst(
    List<Map<String, Object?>> folders,
  ) => parentFirst(folders).reversed.toList(growable: false);

}
