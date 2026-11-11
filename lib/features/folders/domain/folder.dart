class Folder {
  const Folder({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.parentId,
    this.storageUri,
    this.pdfCount = 0,
  });

  final String id;
  final String name;
  final String? parentId;
  final String? storageUri;
  final int pdfCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory Folder.fromMap(Map<String, Object?> map) => Folder(
        id: map['id'] as String,
        name: map['name'] as String,
        parentId: map['parent_id'] as String?,
        storageUri: map['storage_uri_or_relative_path'] as String?,
        pdfCount: (map['pdf_count'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.parse(map['created_at'] as String),
        updatedAt: DateTime.parse(map['updated_at'] as String),
      );
}
