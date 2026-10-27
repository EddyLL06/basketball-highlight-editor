part of '../../mobile_ui.dart';

class _ExportOverlapNotice extends StatelessWidget {
  const _ExportOverlapNotice({required this.state});
  final MobileAppState state;

  @override
  Widget build(BuildContext context) {
    final count = state.exportMergedOverlapCount;
    if (state.exporting ||
        state.exportedPaths.isEmpty ||
        count == null ||
        count <= 0) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: _InlineNotice(message: context.bheText('合并后减少了 $count 个片段')),
    );
  }
}
