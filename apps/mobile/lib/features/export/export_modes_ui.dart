part of '../../mobile_ui.dart';

String _exportLabel(BuildContext context, String? label) {
  if (label == null) return context.bheText('未标记');
  if (label == '未标记') return '$label（${context.bheText('标签')}）';
  return label;
}

class _ExportModeSelector extends StatelessWidget {
  const _ExportModeSelector({
    required this.state,
    required this.mode,
    required this.scope,
    required this.onChanged,
    required this.onStart,
  });
  final MobileAppState state;
  final MobileOutputMode mode;
  final ExportScope scope;
  final ValueChanged<MobileOutputMode> onChanged;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final clips = state.project.candidates
        .where(
          (c) =>
              c.selection == CandidateSelection.included &&
              scope.matches(c),
        )
        .toList();
    final groups = labelExportGroups(clips);
    final outputs = switch (mode) {
      MobileOutputMode.clips => clips.length,
      MobileOutputMode.merged => clips.isEmpty ? 0 : 1,
      MobileOutputMode.labels => groups.length,
    };
    final disabled = state.exportStartBlockReason != null;
    final locale = Localizations.localeOf(context).languageCode;
    final summary = locale == 'en'
        ? '$outputs videos · ${clips.length} clips'
        : '将导出 $outputs 个视频 · 共 ${clips.length} 个片段';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.bheText('输出方式'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            for (final value in MobileOutputMode.values) ...[
              _ExportModeCard(
                mode: value,
                selected: value == mode,
                enabled: !disabled,
                onTap: () => onChanged(value),
              ),
              const SizedBox(height: 8),
            ],
            Text(summary, style: Theme.of(context).textTheme.bodyMedium),
            if (mode == MobileOutputMode.labels && groups.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                groups
                    .map(
                      (group) =>
                          '${_exportLabel(context, group.label)}（${group.candidates.length}）',
                    )
                    .join('、'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: disabled || clips.isEmpty ? null : onStart,
                child: Text(context.bheText('开始导出')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExportModeCard extends StatelessWidget {
  const _ExportModeCard({
    required this.mode,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });
  final MobileOutputMode mode;
  final bool selected, enabled;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final (title, description) = switch (mode) {
      MobileOutputMode.clips => ('每个片段原样导出', '分别保存每个保留片段'),
      MobileOutputMode.merged => ('合并成一个视频', '按时间拼成一条集锦'),
      MobileOutputMode.labels => ('每个标签各合成一个视频', '按标签合成，含未标记'),
    };
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: enabled ? onTap : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: selected ? colors.primary : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.bheText(title),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        context.bheText(description),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// 导出结果里的明确操作用强调色，避免被主题的灰色文字按钮看成不可点。
final _exportActionStyle = TextButton.styleFrom(foregroundColor: BhePalette.orange);

class _LabelExportResultRow extends StatelessWidget {
  const _LabelExportResultRow({required this.state, required this.item});
  final MobileAppState state;
  final LabelExportFile item;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _exportLabel(context, item.label),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (item.label != File(item.path).uri.pathSegments.last)
          Text(
            File(item.path).uri.pathSegments.last,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              style: _exportActionStyle,
              onPressed: () =>
                  unawaited(state.shareExportedFiles(paths: [item.path])),
              child: Text(context.bheText('分享')),
            ),
            TextButton(
              style: _exportActionStyle,
              onPressed: state.exportStartBlockReason == null
                  ? () => unawaited(state.saveExportedFiles(paths: [item.path]))
                  : null,
              child: Text(context.bheText('保存到相册')),
            ),
          ],
        ),
      ],
    ),
  );
}
