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
  @override
  void initState() {
    super.initState();
    widget.state.addListener(changed);
    changed();
  }

  void changed() {
    if (revision == widget.state.reviewRevision) return;
    revision = widget.state.reviewRevision;
    timer?.cancel();
    if (!mounted) return;
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
  Widget build(BuildContext context) => SizedBox(
    height: 96,
    child: message == null
        ? null
        : _InlineNotice(
            message: context.bheText(message!),
            action: message == '已撤销' || message == '保存失败，请重试'
                ? null
                : TextButton(
                    key: const ValueKey('review-undo-action'),
                    onPressed: () => unawaited(widget.state.undoReview()),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      padding: EdgeInsets.zero,
                    ),
                    child: Text(context.bheText('撤销')),
                  ),
          ),
  );
}
