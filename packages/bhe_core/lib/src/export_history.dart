/// Local-only export metadata. Paths are relative to the project's export root.
class ExportHistoryFile {
  const ExportHistoryFile({
    required this.name,
    required this.relativePath,
    this.savedToGallery = false,
    this.untagged = false,
  });
  final String name;
  final String relativePath;
  final bool savedToGallery;
  final bool untagged;

  ExportHistoryFile copyWith({bool? savedToGallery}) => ExportHistoryFile(
    name: name,
    relativePath: relativePath,
    savedToGallery: savedToGallery ?? this.savedToGallery,
    untagged: untagged,
  );
  Map<String, dynamic> toJson() => {
    'name': name,
    'relative_path': relativePath,
    'saved_to_gallery': savedToGallery,
    if (untagged) 'untagged': true,
  };
  static ExportHistoryFile? fromJson(Object? value) {
    if (value is! Map ||
        value['name'] is! String ||
        value['relative_path'] is! String)
      return null;
    final name = value['name'] as String,
        path = value['relative_path'] as String;
    if (name.isEmpty || name.length > 512 || path.isEmpty || path.length > 2048)
      return null;
    return ExportHistoryFile(
      name: name,
      relativePath: path,
      savedToGallery: value['saved_to_gallery'] == true,
      untagged: value['untagged'] == true,
    );
  }
}

class ExportHistoryEntry {
  const ExportHistoryEntry({
    required this.id,
    required this.createdAt,
    required this.mode,
    required this.plannedCount,
    required this.durationMs,
    required this.files,
  });
  final String id;
  final DateTime createdAt;

  /// One of clips, merged, labels.
  final String mode;
  final int plannedCount;
  final int durationMs;
  final List<ExportHistoryFile> files;
  bool get isPartial => files.length < plannedCount;
  ExportHistoryEntry copyWith({List<ExportHistoryFile>? files}) =>
      ExportHistoryEntry(
        id: id,
        createdAt: createdAt,
        mode: mode,
        plannedCount: plannedCount,
        durationMs: durationMs,
        files: files ?? this.files,
      );
  Map<String, dynamic> toJson() => {
    'id': id,
    'created_at': createdAt.toUtc().toIso8601String(),
    'mode': mode,
    'planned_count': plannedCount,
    'duration_ms': durationMs,
    'files': files.map((f) => f.toJson()).toList(),
  };
  static ExportHistoryEntry? fromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['created_at'] is! String ||
        value['mode'] is! String ||
        value['planned_count'] is! num ||
        value['duration_ms'] is! num ||
        value['files'] is! List)
      return null;
    final id = value['id'] as String, mode = value['mode'] as String;
    final created = DateTime.tryParse(value['created_at'] as String);
    final rawPlanned = value['planned_count'] as num;
    final rawDuration = value['duration_ms'] as num;
    if (!rawPlanned.isFinite ||
        !rawDuration.isFinite ||
        rawPlanned < 1 ||
        rawPlanned > 100000 ||
        rawDuration < 0 ||
        rawDuration > 1000000000000000)
      return null;
    final planned = rawPlanned.toInt(), duration = rawDuration.toInt();
    if (id.isEmpty ||
        id.length > 128 ||
        created == null ||
        !const ['clips', 'merged', 'labels'].contains(mode) ||
        planned < 1 ||
        planned > 100000 ||
        duration < 0)
      return null;
    final files = (value['files'] as List)
        .map(ExportHistoryFile.fromJson)
        .whereType<ExportHistoryFile>()
        .toList();
    if (files.isEmpty || files.length > planned) return null;
    return ExportHistoryEntry(
      id: id,
      createdAt: created,
      mode: mode,
      plannedCount: planned,
      durationMs: duration,
      files: files,
    );
  }

  static List<ExportHistoryEntry> readList(Object? value) {
    if (value is! List) return const [];
    return value
        .map(ExportHistoryEntry.fromJson)
        .whereType<ExportHistoryEntry>()
        .take(50)
        .toList();
  }
}
