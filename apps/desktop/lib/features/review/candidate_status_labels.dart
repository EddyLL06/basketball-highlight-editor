import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

class CandidateStatusLabels extends StatelessWidget {
  const CandidateStatusLabels({
    required this.candidateId,
    required this.adjusted,
    required this.overlapsPrevious,
    required this.statusLabel,
    required this.statusColor,
    super.key,
  });

  final String candidateId;
  final bool adjusted;
  final bool overlapsPrevious;
  final String? statusLabel;
  final Color statusColor;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final children = <Widget>[];
    void add(String label, Color color, {String? tooltip, Key? key}) {
      if (children.isNotEmpty) children.add(const SizedBox(width: 4));
      final text = Text(
        context.bheText(label),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      );
      children.add(
        Flexible(
          child: tooltip == null
              ? text
              : Tooltip(
                  key: key,
                  message: context.bheText(tooltip),
                  child: text,
                ),
        ),
      );
    }

    if (adjusted) {
      add(
        '已调整',
        c.amber,
        tooltip: '已调整时长',
        key: ValueKey('adjusted-range-$candidateId'),
      );
    }
    if (overlapsPrevious) {
      add(
        '重叠',
        c.orange,
        tooltip: '与上一段重叠',
        key: ValueKey('overlapping-$candidateId'),
      );
    }
    if (statusLabel != null) add(statusLabel!, statusColor);
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}
