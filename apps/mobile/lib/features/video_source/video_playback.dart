import 'dart:io';

import 'package:video_player/video_player.dart';

import 'video_source_failure.dart';

/// Async even for missing files: never notify app state during widget initState.
Future<VideoPlayerController?> openSourceVideo(
  String path, {
  required bool Function() isCurrent,
  required void Function(VideoSourceFailure) onFailure,
}) async {
  if (!await File(path).exists()) {
    if (isCurrent()) onFailure(VideoSourceFailure.missing);
    return null;
  }
  final player = VideoPlayerController.file(File(path));
  try {
    await player.initialize();
    if (isCurrent()) return player;
  } catch (_) {
    if (isCurrent()) onFailure(VideoSourceFailure.unplayable);
  }
  await player.dispose();
  return null;
}
