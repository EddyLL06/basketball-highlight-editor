part of '../../mobile_ui.dart';

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.message, this.error = false, this.action});
  final String message;
  final bool error;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: (error ? BhePalette.error : BhePalette.warning).withValues(
          alpha: .10,
        ),
        border: Border(
          left: BorderSide(
            color: error ? BhePalette.error : BhePalette.warning,
            width: 2,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            error ? LucideIcons.circleAlert : LucideIcons.info,
            size: 16,
            color: error ? BhePalette.error : BhePalette.warning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n?.text(message) ?? message,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                ?action,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class VideoSourceNotice extends StatelessWidget {
  const VideoSourceNotice({super.key, required this.state});
  final MobileAppState state;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) {
      if (state.errorMessage == null && !state.relinkingVideo) {
        return const SizedBox.shrink();
      }
      final busy = state.relinkingVideo;
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: _InlineNotice(
          message: context.bheText(state.errorMessage ?? '正在重新选择视频'),
          error: true,
          action: !state.canRelinkVideo && !busy
              ? null
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextButton.icon(
                      key: const ValueKey('video-relink'),
                      onPressed: busy || state.preparingVideo || state.exporting
                          ? null
                          : () => unawaited(state.relinkVideo()),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      icon: busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(LucideIcons.folderOpen, size: 18),
                      label: Text(
                        context.bheText(
                          state.relinkCancelling
                              ? '正在取消'
                              : busy
                              ? '正在重新选择视频'
                              : '重新选择视频',
                        ),
                      ),
                    ),
                    if (busy)
                      TextButton(
                        key: const ValueKey('video-relink-cancel'),
                        onPressed: state.relinkCancelling
                            ? null
                            : state.cancelVideoRelink,
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        child: Text(context.bheText('取消')),
                      ),
                  ],
                ),
        ),
      );
    },
  );
}

class VideoSourcePanel extends StatelessWidget {
  const VideoSourcePanel({super.key, required this.state, required this.child});
  final MobileAppState state;
  final Widget child;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      VideoSourceNotice(state: state),
      Expanded(child: child),
    ],
  );
}

class _VideoPreparationCard extends StatelessWidget {
  const _VideoPreparationCard({required this.message, required this.onCancel});

  final String message;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        child: Row(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n?.prepareVideo ?? '正在准备视频',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${l10n?.text(message) ?? message}，${l10n?.text('大文件可能需要几秒') ?? '大文件可能需要几秒'}。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  TextButton(
                    onPressed: onCancel,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    child: Text(context.bheText('取消')),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.action});
  final String title;
  final String? action;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
      if (action != null)
        Flexible(
          child: Text(
            action!,
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
    ],
  );
}
