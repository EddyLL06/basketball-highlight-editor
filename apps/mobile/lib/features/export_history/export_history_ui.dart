part of '../../mobile_ui.dart';

class _ExportHistorySection extends StatefulWidget {
  const _ExportHistorySection({super.key, required this.state});
  final MobileAppState state;
  @override
  State<_ExportHistorySection> createState() => _ExportHistorySectionState();
}

class _ExportHistorySectionState extends State<_ExportHistorySection> {
  bool showAll = false;
  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final entries = state.project.exportHistory;
    final visible = showAll ? entries : entries.take(3).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                context.bheText('导出历史'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              if (state.exportHistoryWarning case final warning?) ...[
                Text(context.bheText(warning)),
                TextButton(
                  onPressed: () => showMobileDiagnostics(
                    context,
                    error: state.diagnosticError,
                  ),
                  child: Text(context.bheText('反馈')),
                ),
              ],
              if (entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(context.bheText('暂无导出记录')),
                ),
              for (final entry in visible)
                _HistoryEntryTile(state: state, entry: entry),
              if (entries.length > 3)
                TextButton(
                  style: _exportActionStyle,
                  onPressed: () => setState(() => showAll = !showAll),
                  child: Text(
                    context.bheText(
                      showAll ? '查看最近 3 条' : '查看全部 ${entries.length} 条',
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HistoryEntryTile extends StatelessWidget {
  const _HistoryEntryTile({required this.state, required this.entry});
  final MobileAppState state;
  final ExportHistoryEntry entry;
  @override
  Widget build(BuildContext context) {
    final date = entry.createdAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final sameYear = date.year == DateTime.now().year;
    final dateText =
        '${sameYear ? '' : '${date.year}-'}${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
    final mode = switch (entry.mode) {
      'merged' => '合并成一个视频',
      'labels' => '每个标签各合成一个视频',
      _ => '每个片段原样导出',
    };
    final theme = Theme.of(context);
    final statusColor = entry.isPartial ? BhePalette.gold : BhePalette.green;
    return ExpansionTile(
      key: ValueKey('history-entry-${entry.id}'),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      expandedAlignment: Alignment.centerLeft,
      tilePadding: EdgeInsets.zero,
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text(
        context.bheText(mode),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleSmall,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$dateText · ${_formatMs(entry.durationMs)}', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: statusColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    entry.isPartial
                        ? context.bheText('部分完成 ${entry.files.length}/${entry.plannedCount}')
                        : context.bheText('全部完成 ${entry.files.length}'),
                    style: theme.textTheme.bodySmall?.copyWith(color: statusColor),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      children: [
        for (final file in entry.files)
          _HistoryFileRow(state: state, file: file),
      ],
    );
  }
}

class _HistoryFileRow extends StatelessWidget {
  const _HistoryFileRow({required this.state, required this.file});
  final MobileAppState state;
  final ExportHistoryFile file;
  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
    future: state.exportHistoryFilePath(file),
    builder: (context, snapshot) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _exportLabel(context, file.untagged ? null : file.name),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (snapshot.connectionState != ConnectionState.done)
            const LinearProgressIndicator()
          else if (snapshot.data case final value?) ...[
            if (file.savedToGallery) Text(context.bheText('已保存到相册')),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  style: _exportActionStyle,
                  onPressed: () =>
                      unawaited(state.shareExportedFiles(paths: [value])),
                  child: Text(context.bheText('分享')),
                ),
                TextButton(
                  style: _exportActionStyle,
                  onPressed: state.exportStartBlockReason == null
                      ? () => unawaited(state.saveExportedFiles(paths: [value]))
                      : null,
                  child: Text(context.bheText('保存到相册')),
                ),
              ],
            ),
          ] else
            Text(
              context.bheText(
                file.savedToGallery ? '已保存到相册，请在相册查看' : '本机文件不可用',
              ),
            ),
        ],
      ),
    ),
  );
}
