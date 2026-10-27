part of '../../mobile_ui.dart';

class _UncertainTaskNotice extends StatelessWidget {
  const _UncertainTaskNotice({
    required this.keyName,
    required this.busy,
    required this.status,
    required this.error,
    required this.onStop,
    required this.onCheck,
  });
  final String keyName;
  final bool busy;
  final String? status;
  final DiagnosticErrorRecord? error;
  final Future<bool> Function() onStop;
  final Future<bool> Function() onCheck;

  @override
  Widget build(BuildContext context) => Card(
    key: ValueKey(keyName),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.bheText('上次任务尚未确认结束，暂时不能开始新的同类任务。')),
          const SizedBox(height: 8),
          Text(
            context.bheText('请先复制诊断信息；若仍无法确认，请在系统设置中强制停止 BHE，重新打开后检查项目和已导出文件。'),
          ),
          if (status case final message?) ...[
            const SizedBox(height: 8),
            Text(context.bheText(message)),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: busy ? null : () => unawaited(onStop()),
                child: Text(context.bheText('再次尝试停止')),
              ),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: busy ? null : () => unawaited(onCheck()),
                child: Text(context.bheText('检查停止状态')),
              ),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                onPressed: () =>
                    unawaited(showMobileDiagnostics(context, error: error)),
                child: Text(context.bheText('诊断与复制')),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _UncertainExportNotice extends StatelessWidget {
  const _UncertainExportNotice({required this.state});
  final MobileAppState state;
  @override
  Widget build(BuildContext context) => _UncertainTaskNotice(
    keyName: 'uncertain-export-notice',
    busy: state.checkingUncertainExport,
    status: state.uncertainExportStatus,
    error: state.uncertainExportDiagnostic,
    onStop: () => state.checkUncertainExport(stopFirst: true),
    onCheck: () => state.checkUncertainExport(),
  );
}
