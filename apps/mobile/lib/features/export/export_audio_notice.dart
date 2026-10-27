part of '../../mobile_ui.dart';

class _ExportAudioNotice extends StatelessWidget {
  const _ExportAudioNotice({required this.state});
  final MobileAppState state;
  @override
  Widget build(BuildContext context) =>
      state.exportAudioSkipped &&
          !state.exporting &&
          state.exportedPaths.isNotEmpty
      ? Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _InlineNotice(message: context.bheText('导出成功，部分音轨无法保留')),
        )
      : const SizedBox.shrink();
}
