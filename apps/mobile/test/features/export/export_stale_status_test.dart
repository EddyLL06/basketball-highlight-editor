import 'dart:async';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/media_bridge.dart';
import 'package:bhe_mobile/features/operation_status/task_stop_status.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.bhe.bhe/mobile_media');
  const video = VideoInfo(
    path: 'source.mp4',
    name: 'source',
    sizeBytes: 8,
    durationMs: 10000,
    width: 100,
    height: 100,
  );
  const clips = [
    Candidate(id: 'A', startMs: 0, endMs: 1000, eventMs: 500),
    Candidate(id: 'B', startMs: 2000, endMs: 3000, eventMs: 2500),
  ];
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  for (final stopFirst in [false, true]) {
    for (final samePath in [false, true]) {
      test(
        'stale status cannot release next owner stop=$stopFirst same=$samePath',
        () async {
          final firstEntered = Completer<void>(),
              firstResult = Completer<Object?>();
          final queryEntered = Completer<void>(),
              queryResult = Completer<Object?>();
          final mergeEntered = Completer<void>(),
              mergeResult = Completer<Object?>();
          var clipsCalled = 0, mergesCalled = 0;
          String? firstPath;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                if (call.method == 'registerMergeExport') return true;
                if (call.method == 'isExportActive') {
                  queryEntered.complete();
                  return queryResult.future;
                }
                if (call.method == 'exportClip') {
                  clipsCalled++;
                  firstPath = (call.arguments as Map)['outputPath'] as String;
                  firstEntered.complete();
                  return firstResult.future;
                }
                if (call.method == 'mergeClips') {
                  mergesCalled++;
                  if (mergesCalled == 1) {
                    mergeEntered.complete();
                    return mergeResult.future;
                  }
                  return {'outputPath': 'third.mp4', 'committed': true};
                }
                return null;
              });
          final engine1 = NativeMediaExportEngine(),
              engine2 = NativeMediaExportEngine(),
              engine3 = NativeMediaExportEngine();
          final old = engine1
              .exportClips(
                video: video,
                candidates: clips,
                outputDirectory: 'out',
              )
              .toList()
              .then<void>((_) {}, onError: (Object _, StackTrace _) {});
          await firstEntered.future;
          final check = engine2.checkPreviousExport(stopFirst: stopFirst);
          await queryEntered.future;
          firstResult.complete({'outputPath': firstPath});
          await old;
          expect(clipsCalled, 1, reason: 'frozen batch must not dispatch B');
          final next = engine2
              .mergeClips(
                video: video,
                candidates: [clips.first],
                outputPath: samePath ? firstPath! : 'other.mp4',
              )
              .toList();
          await mergeEntered.future;
          queryResult.complete(false);
          expect(await check, TaskStopStatus.unknown);
          final third = engine3
              .mergeClips(
                video: video,
                candidates: [clips.first],
                outputPath: 'third.mp4',
              )
              .toList();
          await pumpEventQueue();
          expect(mergesCalled, 1);
          mergeResult.complete({'outputPath': 'second.mp4', 'committed': true});
          await next;
          await third;
          expect(mergesCalled, 2);
        },
      );
    }
  }
}
