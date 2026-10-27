import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../video_source/video_playback.dart';
import '../video_source/video_source_failure.dart';

/// Owns the editor's player. Failed initialization or transport never leaves
/// a half-ready controller available to the drawing controls.
class RoiVideoPreview extends ChangeNotifier {
  VideoPlayerController? controller;
  VideoSourceFailure? failure;
  bool _disposed = false;
  int _generation = 0;
  String _path = '';

  Future<void> _release(VideoPlayerController? player) async {
    try {
      await player?.dispose();
    } catch (error, stack) {
      developer.log(
        'ROI player disposal failed',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<void> open(String path, int positionMs) async {
    final generation = ++_generation;
    _path = path;
    bool current() => !_disposed && generation == _generation;
    final player = await openSourceVideo(
      path,
      isCurrent: current,
      onFailure: (error) {
        failure = error;
        notifyListeners();
      },
    );
    if (player == null) return;
    try {
      await player.seekTo(
        Duration(
          milliseconds: positionMs.clamp(
            0,
            player.value.duration.inMilliseconds,
          ),
        ),
      );
      if (!current()) {
        await _release(player);
        return;
      }
      controller = player;
      player.addListener(_changed);
      notifyListeners();
    } catch (_) {
      await _release(player);
      if (current()) _failed();
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _failed() {
    failure = File(_path).existsSync()
        ? VideoSourceFailure.unplayable
        : VideoSourceFailure.missing;
    notifyListeners();
  }

  Future<void> run(Future<void> Function(VideoPlayerController) action) async {
    final player = controller;
    if (_disposed || player == null) return;
    final generation = _generation;
    try {
      await action(player);
    } catch (_) {
      if (_disposed || generation != _generation) return;
      controller = null;
      player.removeListener(_changed);
      await _release(player);
      if (!_disposed && generation == _generation) _failed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    final player = controller;
    controller = null;
    player?.removeListener(_changed);
    unawaited(_release(player));
    super.dispose();
  }
}
