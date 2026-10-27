part of '../../mobile_ui.dart';

Future<void> _loadReviewVideo(_ReviewViewState view) async {
  final state = view.state;
  final path = view._openedVideoPath = state.project.video?.path;
  view._openedSourceRevision = state.videoSourceRevision;
  final generation = ++view._videoOpenGeneration;
  final projectId = state.project.id;
  bool current() =>
      view.mounted &&
      generation == view._videoOpenGeneration &&
      state.project.id == projectId;
  final next = path == null
      ? null
      : await openSourceVideo(
          path,
          isCurrent: current,
          onFailure: state.markVideoFailure,
        );
  if (!current()) {
    await next?.dispose();
    return;
  }
  next?.addListener(view._videoChanged);
  final previous = view.controller;
  view._installSourcePlayer(next);
  await previous?.dispose();
  if (next != null && current() && view.candidates.isNotEmpty) {
    try {
      await view._replay(view.candidates.first);
    } catch (_) {
      if (current()) state.markVideoFailure(VideoSourceFailure.unplayable);
    }
  }
}

class _ReviewSourceBody extends StatelessWidget {
  const _ReviewSourceBody({required this.rail, required this.video});
  final Widget rail;
  final Widget video;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Existing progress controls: 48dp + 2dp padding; filter strip: 34dp.
      // Keep these visible when a source notice reduces the available height.
      final railHeight = math.max(
        constraints.maxHeight * .4,
        math.min(84.0, constraints.maxHeight),
      );
      return Column(
        children: [
          SizedBox(height: railHeight, child: rail),
          Expanded(child: video),
        ],
      );
    },
  );
}
