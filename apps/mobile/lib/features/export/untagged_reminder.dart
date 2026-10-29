part of '../../mobile_ui.dart';

/// 导出前提醒：本次导出会带上还没标标签的保留片段时先问一下，不改任何数据。
/// 只在项目在用标签（有球员名单或已有片段标了标签）、且导出范围包含未标记片段
/// 时提醒；筛选了导出范围（包括主动勾选未标记）、或「每个标签各合成」（未标记单独成组并在摘要里列出）不提醒。
int _untaggedReminderCount(
  MobileAppState state,
  ExportScope scope,
  MobileOutputMode mode,
) {
  if (scope.active || mode == MobileOutputMode.labels) return 0;
  bool tagged(Candidate candidate) => candidate.player?.trim().isNotEmpty ?? false;
  final kept = state.project.candidates
      .where((candidate) => candidate.selection == CandidateSelection.included)
      .toList();
  final untagged = kept.where((candidate) => !tagged(candidate)).length;
  if (untagged == 0) return 0;
  final usesLabels = state.project.players.isNotEmpty || kept.any(tagged);
  return usesLabels ? untagged : 0;
}

enum _UntaggedChoice { backToReview, exportAnyway }

Future<_UntaggedChoice?> _showUntaggedReminder(BuildContext context, int count) =>
    showDialog<_UntaggedChoice>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('untagged-reminder'),
        title: Text(context.bheText('还有 $count 个片段未标标签')),
        content: Text(context.bheText('本次导出会包含这些片段。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(_UntaggedChoice.backToReview),
            child: Text(context.bheText('返回审核')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_UntaggedChoice.exportAnyway),
            child: Text(context.bheText('仍然导出')),
          ),
        ],
      ),
    );
