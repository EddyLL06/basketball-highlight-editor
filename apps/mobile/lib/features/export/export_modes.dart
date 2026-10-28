import 'package:bhe_core/bhe_core.dart';

enum MobileOutputMode { clips, merged, labels }

class LabelExportGroup {
  const LabelExportGroup(this.label, this.candidates);
  final String? label;
  final List<Candidate> candidates;
}

class LabelExportFile {
  const LabelExportFile(this.label, this.path);
  final String? label;
  final String path;
}

List<LabelExportGroup> labelExportGroups(Iterable<Candidate> candidates) {
  final groups = <String?, List<Candidate>>{};
  for (final candidate in candidates) {
    final value = candidate.player;
    final label = value == null || value.trim().isEmpty ? null : value;
    (groups[label] ??= []).add(candidate);
  }
  return [
    for (final entry in groups.entries)
      LabelExportGroup(entry.key, entry.value),
  ];
}
