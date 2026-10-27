import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class FakeVideoPlatform extends VideoPlayerPlatform {
  bool failInitialize = false;
  bool failSeek = false;
  int nextId = 0;
  final sources = <int, DataSource>{};
  final disposed = <int>[];
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = nextId++;
    sources[id] = options.dataSource;
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => failInitialize
      ? Stream.error(
          PlatformException(
            code: 'VideoError',
            message: 'injected initialization failure',
          ),
        )
      : Stream.value(
          VideoEvent(
            eventType: VideoEventType.initialized,
            size: const Size(1920, 1080),
            duration: const Duration(seconds: 10),
          ),
        );
  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> play(int playerId) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) async {}
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Future<void> seekTo(int playerId, Duration position) async {
    if (failSeek) throw PlatformException(code: 'seek_failed');
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();
}
