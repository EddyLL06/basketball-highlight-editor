part of '../../mobile_ui.dart';

Future<void> showMobileDiagnostics(
  BuildContext context, {
  DiagnosticErrorRecord? error,
  MobileDiagnostics? diagnostics,
  Future<void> Function(String)? copy,
  Future<bool> Function(String)? open,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _DiagnosticSheet(
      error: error,
      diagnostics: diagnostics ?? MobileDiagnostics.instance,
      copy: copy ?? (value) => Clipboard.setData(ClipboardData(text: value)),
      open:
          open ??
          (value) =>
              launchUrl(Uri.parse(value), mode: LaunchMode.externalApplication),
    ),
  );
}

class _DiagnosticSheet extends StatefulWidget {
  const _DiagnosticSheet({
    required this.diagnostics,
    required this.copy,
    required this.open,
    this.error,
  });
  final MobileDiagnostics diagnostics;
  final DiagnosticErrorRecord? error;
  final Future<void> Function(String) copy;
  final Future<bool> Function(String) open;
  @override
  State<_DiagnosticSheet> createState() => _DiagnosticSheetState();
}

class _DiagnosticSheetState extends State<_DiagnosticSheet> {
  String? _report;
  String? _notice;
  bool _started = false;
  bool _copied = false;
  Timer? _timer;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final l10n = Localizations.of<BheLocalizations>(context, BheLocalizations);
    String text(String value) => l10n?.text(value) ?? value;
    String report;
    try {
      report = await buildMobileDiagnosticReport(
        widget.diagnostics,
        error: widget.error,
        text: text,
      );
    } catch (error, stack) {
      widget.diagnostics.error(error, stack, operation: 'diagnostics.report');
      report = text('诊断信息暂时不可用。');
    }
    if (mounted) setState(() => _report = report);
  }

  Future<void> _copy() async {
    final report = _report;
    if (report == null) return;
    try {
      await widget.copy(report);
      if (!mounted) return;
      _timer?.cancel();
      setState(() {
        _copied = true;
        _notice = null;
      });
      _timer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _copied = false);
      });
    } catch (error, stack) {
      widget.diagnostics.error(error, stack, operation: 'diagnostics.copy');
      if (mounted) setState(() => _notice = '复制失败，请重试。');
    }
  }

  Future<void> _open(String value) async {
    try {
      if (await widget.open(value)) return;
    } catch (error, stack) {
      widget.diagnostics.error(error, stack, operation: 'diagnostics.open');
    }
    if (mounted) setState(() => _notice = '无法打开反馈入口，请先复制诊断信息。');
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height =
        (MediaQuery.sizeOf(context).height -
            MediaQuery.viewInsetsOf(context).bottom) *
        .85;
    final english =
        Localizations.of<BheLocalizations>(
          context,
          BheLocalizations,
        )?.localeName.startsWith('en') ==
        true;
    final actionStyle = TextButton.styleFrom(minimumSize: const Size(48, 48));
    return SizedBox(
      key: const ValueKey('diagnostics-sheet'),
      height: height,
      child: _SheetFrame(
        title: context.bheText('反馈与诊断'),
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        titleStyle: theme.textTheme.titleMedium?.copyWith(
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(context.bheText('遇到问题时，把下面的信息发给我们。已隐藏你的用户名和文件路径。')),
            const SizedBox(height: 12),
            SizedBox(
              key: const ValueKey('diagnostics-preview'),
              height: height * .45,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _report == null
                      ? const Center(child: CircularProgressIndicator())
                      : SingleChildScrollView(
                          child: SelectableText(
                            _report!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(context.bheText(_notice!)),
              ),
            FilledButton(
              key: const ValueKey('diagnostics-copy'),
              onPressed: _report == null ? null : _copy,
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              child: Text(context.bheText(_copied ? '已复制' : '复制诊断信息')),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const ValueKey('diagnostics-github'),
              onPressed: () => _open(githubIssueUrl),
              style: actionStyle,
              child: Text(context.bheText('在 GitHub 反馈')),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              key: const ValueKey('diagnostics-email'),
              onPressed: () => _open(
                feedbackMailto(appVersion: mobileAppVersion, english: english),
              ),
              style: actionStyle,
              child: Text(context.bheText('发邮件')),
            ),
          ],
        ),
      ),
    );
  }
}
