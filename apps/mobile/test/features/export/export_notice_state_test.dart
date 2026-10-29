import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
  test(
    'failure, separate export and project switch clear successful merge count',
    () async {
      final source = await f.file('original.mp4', 'original');
      f.state.project = f.project(source.path);
      var fail = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'mergeClips') {
              if (fail) throw PlatformException(code: 'EXPORT_FAILED');
              return {
                'outputPath': (call.arguments as Map)['outputPath'],
                'mergedOverlapCount': 2,
              };
            }
            if (call.method == 'exportClip') {
              return (call.arguments as Map)['outputPath'];
            }
            return null;
          });
      await f.state.mergeClips();
      expect(f.state.exportMergedOverlapCount, 2);
      fail = true;
      await f.state.mergeClips();
      expect(f.state.exportMergedOverlapCount, isNull);
      fail = false;
      await f.state.mergeClips();
      expect(f.state.exportMergedOverlapCount, 2);
      await f.state.exportClips();
      expect(f.state.exportMergedOverlapCount, isNull);
      await f.state.mergeClips();
      expect(f.state.exportMergedOverlapCount, 2);
      await f.state.createNewProject();
      expect(f.state.exportMergedOverlapCount, isNull);
    },
  );
  test(
    'cancel clears pending merge notice and failed request never restores it',
    () async {
      final source = await f.file('original.mp4', 'original');
      f.state.project = f.project(source.path);
      final entered = Completer<void>(), release = Completer<Object?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'mergeClips') {
              entered.complete();
              return release.future;
            }
            return null;
          });
      final pending = f.state.mergeClips();
      await entered.future;
      await f.state.cancelExport();
      expect(f.state.exportMergedOverlapCount, isNull);
      release.completeError(PlatformException(code: 'EXPORT_CANCELLED'));
      await pending;
      expect(f.state.exportMergedOverlapCount, isNull);
    },
  );
  test(
    'cancel while resolving output path prevents native registration or merge',
    () async {
      final source = await f.file('original.mp4', 'original');
      f.state.project = f.project(source.path);
      final existing = await f.file(
        'BHE Mobile/exports/A/A_merged.mp4',
        'previous',
      );
      final entered = Completer<void>(), release = Completer<void>();
      var first = true, calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async {
              if (first) {
                first = false;
                entered.complete();
                await release.future;
              }
              return f.root.path;
            },
          );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'mergeClips' ||
                call.method == 'registerMergeExport') {
              calls++;
            }
            return null;
          });
      try {
        final pending = f.state.mergeClips();
        await entered.future;
        await f.state.cancelExport();
        release.complete();
        await pending;
        expect(calls, 0);
        expect(await existing.readAsString(), 'previous');
        expect(f.state.exportMergedOverlapCount, isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async => f.root.path,
            );
      }
    },
  );
}
