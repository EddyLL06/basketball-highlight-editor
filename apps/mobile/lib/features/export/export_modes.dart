import 'package:bhe_core/bhe_core.dart';

enum MobileOutputMode { clips, merged, labels }

/// 导出范围，和桌面端一致：没筛选就是全部保留片段；筛选后只导出选中的标签，
/// 「未标记」要单独勾选。
class ExportScope {
  const ExportScope.only(this.players, {this.includeUntagged = false})
    : active = true;
  const ExportScope._all() : active = false, players = const {}, includeUntagged = true;

  static const all = ExportScope._all();

  final bool active;
  final Set<String> players;
  final bool includeUntagged;

  bool matches(Candidate candidate) {
    if (!active) return true;
    final name = candidate.player;
    final untagged = name == null || name.trim().isEmpty;
    return untagged ? includeUntagged : players.contains(name);
  }

  /// 没有任何选中项时等于没筛选，避免出现"筛选了却什么都不导出"。
  ExportScope get normalized =>
      active && players.isEmpty && !includeUntagged ? all : this;
}

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
