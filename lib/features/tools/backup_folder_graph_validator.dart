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
}
