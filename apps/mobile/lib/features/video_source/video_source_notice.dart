part of '../../mobile_ui.dart';

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({
    super.key,
    required this.message,
    this.error = false,
    this.action,
  });
  final String message;
  final bool error;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(12, 10, 12, action == null ? 10 : 4),
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
              mainAxisSize: MainAxisSize.min,
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
  const VideoSourceNotice({
    super.key,
    required this.state,
    this.suppressReviewFailure = false,
  });
  final MobileAppState state;
  final bool suppressReviewFailure;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) {
      final reviewFailure =
          suppressReviewFailure &&
          state.reviewDiagnosticError != null &&
          identical(state.diagnosticError, state.reviewDiagnosticError);
      final message = reviewFailure
          ? state.videoSourceFailure?.message
          : state.errorMessage;
      if (message == null && !state.relinkingVideo) {
        return const SizedBox.shrink();
      }
      final busy = state.relinkingVideo;
      final actionStyle = TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: EdgeInsets.zero,
        alignment: Alignment.centerLeft,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: _InlineNotice(
          key: const ValueKey('video-source-notice'),
          message: context.bheText(message ?? '正在重新选择视频'),
          error: true,
          action: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (state.canRelinkVideo || busy)
                TextButton(
                  key: const ValueKey('video-relink'),
                  onPressed: busy || state.preparingVideo || state.exporting
                      ? null
                      : () => unawaited(state.relinkVideo()),
                  style: actionStyle,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (busy) ...[
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Text(
                          context.bheText(
                            state.relinkCancelling
                                ? '正在取消'
                                : busy
                                ? '正在重新选择视频'
                                : '重新选择视频',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (busy)
                TextButton(
                  key: const ValueKey('video-relink-cancel'),
                  onPressed: state.relinkCancelling
                      ? null
                      : state.cancelVideoRelink,
                  style: actionStyle,
                  child: Text(context.bheText('取消')),
                ),
              if (message != null)
                TextButton(
                  key: const ValueKey('video-feedback'),
                  onPressed: () => showMobileDiagnostics(
                    context,
                    error:
                        (reviewFailure ? null : state.diagnosticError) ??
                        DiagnosticErrorRecord(
                          StateError(message),
                          null,
                          'video',
                        ),
                  ),
                  style: actionStyle,
                  child: Text(context.bheText('反馈')),
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
      VideoSourceNotice(state: state, suppressReviewFailure: true),
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
                    context.bheText('$message，大文件可能需要几秒。'),
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
