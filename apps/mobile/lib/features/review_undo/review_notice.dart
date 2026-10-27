part of '../../mobile_ui.dart';

class _ReviewUndoNotice extends StatefulWidget {
  const _ReviewUndoNotice({required this.state});
  final MobileAppState state;
  @override
  State<_ReviewUndoNotice> createState() => _ReviewUndoNoticeState();
}

class _ReviewUndoNoticeState extends State<_ReviewUndoNotice> {
  Timer? timer;
  int revision = -1;
  String? message;
  DiagnosticErrorRecord? failureRecord;
  @override
  void initState() {
    super.initState();
    widget.state.addListener(changed);
    changed();
  }

  void changed() {
    if (revision == widget.state.reviewRevision) return;
    revision = widget.state.reviewRevision;
    if (message == '保存失败，请重试' &&
        widget.state.reviewNotice != null &&
        widget.state.reviewNotice != message &&
        (timer?.isActive ?? false)) {
      return;
    }
    timer?.cancel();
    if (!mounted) return;
    if (widget.state.reviewNotice == '保存失败，请重试') {
      failureRecord = widget.state.reviewDiagnosticError;
    } else if (widget.state.reviewNotice == null) {
      failureRecord = null;
    }
    final at = widget.state.reviewNoticeAt;
    final remaining = at == null
        ? Duration.zero
        : const Duration(seconds: 5) - DateTime.now().difference(at);
    setState(
      () => message = remaining > Duration.zero
          ? widget.state.reviewNotice
          : null,
    );
    if (message != null) {
      timer = Timer(remaining, () {
        if (mounted) setState(() => message = null);
      });
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.state.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final failed = message == '保存失败，请重试';
    return SizedBox(
      height: 96,
      child: message == null
          ? null
          : Material(
              key: const ValueKey('review-notice-surface'),
              color: colors.surface,
              child: _InlineNotice(
                message: context.bheText(message!),
                error: failed,
                textColor: colors.onSurface,
                action: failed && failureRecord != null
                    ? TextButton(
                        key: const ValueKey('review-feedback-action'),
                        onPressed: () => showMobileDiagnostics(
                          context,
                          error: failureRecord,
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: colors.onSurface,
                          minimumSize: const Size(48, 48),
                          padding: EdgeInsets.zero,
                        ),
                        child: Text(context.bheText('反馈')),
                      )
                    : message == '已撤销' || failed
                    ? null
                    : TextButton(
                        key: const ValueKey('review-undo-action'),
                        onPressed: () => unawaited(widget.state.undoReview()),
                        style: TextButton.styleFrom(
                          foregroundColor: colors.onSurface,
                          minimumSize: const Size(48, 48),
                          padding: EdgeInsets.zero,
                        ),
                        child: Text(context.bheText('撤销')),
                      ),
              ),
            ),
    );
  }
}
