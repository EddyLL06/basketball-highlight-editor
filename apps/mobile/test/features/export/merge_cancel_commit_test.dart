import 'dart:async';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/media_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.bhe.bhe/mobile_media');
  const video = VideoInfo(
    path: 'source.mp4',
    name: 'source',
    sizeBytes: 1,
    durationMs: 10000,
    width: 100,
    height: 100,
  );
  const clips = [Candidate(id: 'c', startMs: 0, endMs: 1000, eventMs: 500)];
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  for (final committed in [true, false]) {
    test(
      'merge cancellation after native ${committed ? 'commit' : 'uncommitted legacy result'}',
      () async {
        final entered = Completer<void>(), release = Completer<Object?>();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'mergeClips') {
                entered.complete();
                return release.future;
              }
              return null;
            });
        final engine = NativeMediaExportEngine();
        final result = engine
            .mergeClips(video: video, candidates: clips, outputPath: 'out.mp4')
            .toList();
        await entered.future;
        await engine.cancel();
        release.complete(
          committed
              ? {
                  'outputPath': 'out.mp4',
                  'mergedOverlapCount': 1,
                  'committed': true,
                }
              : 'out.mp4',
        );
        if (committed) {
          final updates = await result;
          expect(updates.last.outputPath, 'out.mp4');
          expect(updates.last.mergedOverlapCount, 1);
        } else {
          await expectLater(result, throwsA(isA<MobileExportException>()));
        }
      },
    );
  }
}
