import 'dart:async';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.bhe.bhe/mobile_media');
  late MobileVideoFixture f;
  setUp(() async {
    f = MobileVideoFixture();
    await f.init();
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await f.close();
  });
  for (final cancelReturnsFirst in [true, false]) {
    test(
      'committed result wins when cancel returns ${cancelReturnsFirst ? 'before' : 'after'} success',
      () async {
        final source = await f.file('original.mp4', 'original');
        f.state.project = f.project(source.path);
        final started = Completer<void>(),
            mergeResult = Completer<Object?>(),
            cancelEntered = Completer<void>(),
            cancelResult = Completer<void>();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'mergeClips') {
                started.complete();
                return mergeResult.future;
              }
              if (call.method == 'cancelExport') {
                cancelEntered.complete();
                await cancelResult.future;
              }
              return null;
            });
        final pending = f.state.mergeClips();
        await started.future;
        final cancel = f.state.cancelExport();
        await cancelEntered.future;
        if (cancelReturnsFirst) {
          cancelResult.complete();
          await cancel;
        }
        mergeResult.complete({
          'outputPath': 'out.mp4',
          'mergedOverlapCount': 1,
          'committed': true,
        });
        await pending;
        if (!cancelReturnsFirst) {
          cancelResult.complete();
          await cancel;
        }
        expect(f.state.exportCancelled, isFalse);
        expect(f.state.exportMergedOverlapCount, 1);
        expect(f.state.exportedPaths, ['out.mp4']);
        expect(f.state.progressMessage, '合并导出完成');
        expect(f.state.errorMessage, isNull);
      },
    );
  }
  test(
    'actual native cancellation remains cancelled and has no completed file',
    () async {
      final source = await f.file('original.mp4', 'original');
      f.state.project = f.project(source.path);
      final entered = Completer<void>(), finish = Completer<Object?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'mergeClips') {
              entered.complete();
              return finish.future;
            }
            return null;
          });
      final pending = f.state.mergeClips();
      await entered.future;
      await f.state.cancelExport();
      finish.completeError(PlatformException(code: 'EXPORT_CANCELLED'));
      await pending;
      expect(f.state.exportCancelled, isTrue);
      expect(f.state.exportedPaths, isEmpty);
      expect(f.state.exportMergedOverlapCount, isNull);
    },
  );

  test('late cancel reply cannot overwrite a later save operation', () async {
    final source = await f.file('original.mp4', 'original');
    f.state.project = f.project(source.path);
    final entered = Completer<void>(),
        mergeResult = Completer<Object?>(),
        cancelEntered = Completer<void>(),
        cancelResult = Completer<void>();
    final saving = Completer<void>(), saveResult = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'mergeClips') {
            entered.complete();
            return mergeResult.future;
          }
          if (call.method == 'cancelExport') {
            cancelEntered.complete();
            await cancelResult.future;
          }
          if (call.method == 'saveToLibrary') {
            saving.complete();
            await saveResult.future;
          }
          return null;
        });
    final pending = f.state.mergeClips();
    await entered.future;
    final cancel = f.state.cancelExport();
    await cancelEntered.future;
    mergeResult.complete({
      'outputPath': 'out.mp4',
      'mergedOverlapCount': 1,
      'committed': true,
    });
    await pending;
    final save = f.state.saveExportedFiles();
    await saving.future;
    cancelResult.complete();
    await cancel;
    expect(f.state.progressMessage, '正在保存到相册 1/1');
    saveResult.complete();
    await save;
    expect(f.state.progressMessage, '已保存 1 个片段到相册');
  });
  testWidgets(
    'committed result triggers completion flow despite a late cancel reply',
    (tester) async {
      final previous = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = FakeVideoPlatform();
      try {
        final source = await tester.runAsync(
          () => f.file('original.mp4', 'original'),
        );
        f.state.project = f.project(source!.path);
        await tester.pumpWidget(BheMobileApp(appState: f.state));
        await tester.pump();
        await tester.runAsync(() async {
          final started = Completer<void>();
          final mergeResult = Completer<Object?>();
          final cancelEntered = Completer<void>();
          final cancelResult = Completer<void>();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                if (call.method == 'mergeClips') {
                  started.complete();
                  return mergeResult.future;
                }
                if (call.method == 'cancelExport') {
                  cancelEntered.complete();
                  await cancelResult.future;
                }
                return null;
              });
          final pending = f.state.mergeClips();
          await started.future;
          final cancel = f.state.cancelExport();
          await cancelEntered.future;
          mergeResult.complete({
            'outputPath': 'out.mp4',
            'mergedOverlapCount': 1,
            'committed': true,
          });
          await pending;
          cancelResult.complete();
          await cancel;
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final shown = await tester.runAsync(
          () async => (await SharedPreferences.getInstance()).getBool(
            'bhe.github-star-prompt-shown',
          ),
        );
        expect(shown, isTrue);
        expect(f.state.exportCancelled, isFalse);
        expect(f.state.progressMessage, '合并导出完成');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => pumpEventQueue());
        VideoPlayerPlatform.instance = previous;
      }
    },
  );
}
