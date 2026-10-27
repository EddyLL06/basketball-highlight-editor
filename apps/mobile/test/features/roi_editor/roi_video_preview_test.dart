import 'dart:io';

import 'package:bhe_mobile/features/roi_editor/roi_video_preview.dart';
import 'package:bhe_mobile/features/video_source/video_source_failure.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../../support/fake_video_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late FakeVideoPlatform platform;
  late VideoPlayerPlatform previous;
  late RoiVideoPreview preview;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('bhe_roi_');
    platform = FakeVideoPlatform();
    previous = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = platform;
    preview = RoiVideoPreview();
  });
  tearDown(() async {
    preview.dispose();
    await pumpEventQueue();
    VideoPlayerPlatform.instance = previous;
    await root.delete(recursive: true);
  });
  Future<String> source() async {
    final file = File('${root.path}/video.mp4');
    await file.writeAsString('fake video uses injected platform');
    return file.path;
  }

  test('missing file offers recovery without creating a player', () async {
    await preview.open('${root.path}/missing.mp4', 0);
    expect(preview.failure, VideoSourceFailure.missing);
    expect(preview.controller, isNull);
    expect(platform.sources, isEmpty);
  });
  test(
    'initialization error releases failed player and exposes reason',
    () async {
      platform.failInitialize = true;
      await preview.open(await source(), 0);
      expect(preview.failure, VideoSourceFailure.unplayable);
      expect(preview.diagnosticError?.error, isA<PlatformException>());
      expect(preview.controller, isNull);
      expect(platform.disposed, [0]);
    },
  );
  test('initial seek error releases player before enabling editing', () async {
    platform.failSeek = true;
    await preview.open(await source(), 1200);
    expect(preview.failure, VideoSourceFailure.unplayable);
    expect(preview.controller, isNull);
    expect(platform.disposed, [0]);
  });
  test(
    'later seek error is handled, disables playback and cannot be retried on stale player',
    () async {
      await preview.open(await source(), 0);
      expect(preview.controller, isNotNull);
      platform.failSeek = true;
      await preview.run((player) => player.seekTo(const Duration(seconds: 2)));
      expect(preview.failure, VideoSourceFailure.unplayable);
      expect(preview.controller, isNull);
      expect(platform.disposed, [0]);
      var invoked = false;
      await preview.run((_) async {
        invoked = true;
      });
      expect(invoked, isFalse);
    },
  );
}
