import 'dart:async';
import 'dart:io';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/media_bridge.dart';
import 'package:bhe_mobile/mobile_app_state.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';

class _UncertainState extends MobileAppState {
  @override
  bool get hasUncertainExport => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.bhe.bhe/mobile_media');
  late MobileVideoFixture f;
  var closed = false;
  setUp(() {
    closed = false;
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (!closed) await f.close();
  });
  test(
    'old native task remains visible across switch and only confirmed cleanup unlocks',
    () async {
      final entered = Completer<void>(), result = Completer<Object?>();
      var active = true, failStop = false, calls = 0, stops = 0;
      f = MobileVideoFixture();
      await f.init(
        exportEngine: NativeMediaExportEngine(
          drainTimeout: const Duration(milliseconds: 40),
        ),
        exportDrainTimeout: const Duration(milliseconds: 40),
      );
      final file = await f.file('original.mp4', 'original');
      f.state.project = f.project(file.path);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'registerMergeExport') return true;
            if (call.method == 'mergeClips') {
              calls++;
              entered.complete();
              return result.future;
            }
            if (call.method == 'cancelExport') {
              stops++;
              if (failStop) throw PlatformException(code: 'FAIL');
              return null;
            }
            if (call.method == 'isExportActive') return active;
            return null;
          });
      final old = f.state.mergeClips();
      await entered.future;
      await f.state.createNewProject();
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(f.state.hasUncertainExport, isTrue);
      expect(f.state.uncertainExportDiagnostic, isNotNull);
      await f.state.openProject('A');
      expect(f.state.hasUncertainExport, isTrue);
      expect(await f.state.checkUncertainExport(), TaskStopStatus.running);
      failStop = true;
      expect(
        await f.state.checkUncertainExport(stopFirst: true),
        TaskStopStatus.unknown,
      );
      expect(f.state.hasUncertainExport, isTrue);
      failStop = false;
      expect(
        await f.state.checkUncertainExport(stopFirst: true),
        TaskStopStatus.running,
      );
      expect(f.state.hasUncertainExport, isTrue);
      expect(calls, 1);
      expect(stops, greaterThanOrEqualTo(3));
      active = false;
      expect(await f.state.checkUncertainExport(), TaskStopStatus.stopped);
      await pumpEventQueue();
      expect(f.state.hasUncertainExport, isFalse);
      result.completeError(PlatformException(code: 'EXPORT_CANCELLED'));
      await old;
    },
  );
  test(
    'hung release reply retains gate until native confirms cleanup',
    () async {
      final release = Completer<void>();
      var active = true, merges = 0;
      f = MobileVideoFixture();
      await f.init(
        exportEngine: NativeMediaExportEngine(
          drainTimeout: const Duration(milliseconds: 35),
        ),
      );
      final file = await f.file('original.mp4', 'original');
      f.state.project = f.project(file.path);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'registerMergeExport') return true;
            if (call.method == 'mergeClips') {
              merges++;
              return {
                'outputPath': 'done.mp4',
                'committed': true,
                'mergedOverlapCount': 2,
              };
            }
            if (call.method == 'releaseMergeExport') {
              await release.future;
              return null;
            }
            if (call.method == 'isExportActive') return active;
            return null;
          });
      await f.state.mergeClips();
      expect(f.state.exportedPaths, ['done.mp4']);
      expect(f.state.exportMergedOverlapCount, 2);
      expect(f.state.errorMessage, isNull);
      expect(f.state.diagnosticError, isNull);
      expect(f.state.project.lastExportDurationMs, isNotNull);
      final disk = const ProjectPackageCodec().decode(
        await File('${f.data.path}/projects/A.json').readAsString(),
      );
      expect(disk.lastExportDurationMs, isNotNull);
      expect(f.state.hasUncertainExport, isTrue);
      expect(f.state.uncertainExportDiagnostic, isNotNull);
      expect(await f.state.checkUncertainExport(), TaskStopStatus.running);
      await f.state.mergeClips();
      expect(merges, 1);
      active = false;
      expect(await f.state.checkUncertainExport(), TaskStopStatus.stopped);
      await pumpEventQueue();
      expect(f.state.hasUncertainExport, isFalse);
      release.complete();
    },
  );
  test(
    'committed merge with release error retains successful result',
    () async {
      var active = true;
      f = MobileVideoFixture();
      await f.init();
      final file = await f.file('original.mp4', 'original');
      f.state.project = f.project(file.path);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'registerMergeExport') return true;
            if (call.method == 'mergeClips') {
              return {
                'outputPath': 'done.mp4',
                'committed': true,
                'mergedOverlapCount': 2,
              };
            }
            if (call.method == 'releaseMergeExport') {
              throw PlatformException(code: 'RELEASE_FAIL');
            }
            if (call.method == 'isExportActive') return active;
            return null;
          });
      await f.state.mergeClips();
      expect(f.state.errorMessage, isNull);
      expect(f.state.exportedPaths, ['done.mp4']);
      expect(f.state.exportMergedOverlapCount, 2);
      expect(f.state.project.lastExportDurationMs, isNotNull);
      expect(f.state.hasUncertainExport, isTrue);
      active = false;
      expect(await f.state.checkUncertainExport(), TaskStopStatus.stopped);
      await pumpEventQueue();
    },
  );
  testWidgets('committed result runs completion UI when release stalls', (
    tester,
  ) async {
    f = MobileVideoFixture();
    await tester.runAsync(
      () => f.init(
        exportEngine: NativeMediaExportEngine(
          drainTimeout: const Duration(milliseconds: 35),
        ),
      ),
    );
    final previous = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = FakeVideoPlatform();
    final release = Completer<void>();
    tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
    try {
      await tester.runAsync(() async {
        final file = await f.file('original.mp4', 'original');
        f.state.project = f.project(file.path);
      });
      await tester.pumpWidget(BheMobileApp(appState: f.state));
      await tester.pump();
      await tester.tap(find.byTooltip('导出'));
      await tester.pump();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'registerMergeExport') return true;
            if (call.method == 'mergeClips') {
              return {
                'outputPath': 'done.mp4',
                'committed': true,
                'mergedOverlapCount': 2,
              };
            }
            if (call.method == 'releaseMergeExport') {
              await release.future;
              return null;
            }
            if (call.method == 'isExportActive') return false;
            return null;
          });
      await tester.runAsync(() => f.state.mergeClips());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(f.state.errorMessage, isNull);
      expect(f.state.exportedPaths, ['done.mp4']);
      expect(f.state.hasUncertainExport, isTrue);
      expect(
        find.byKey(const ValueKey('uncertain-export-notice')),
        findsOneWidget,
      );
      final shown = await tester.runAsync(
        () async => (await SharedPreferences.getInstance()).getBool(
          'bhe.github-star-prompt-shown',
        ),
      );
      expect(shown, isTrue);
      await tester.runAsync(() => f.state.checkUncertainExport());
      release.complete();
      await tester.pump();
    } finally {
      if (!release.isCompleted) release.complete();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => f.close());
      closed = true;
      tester.binding.platformDispatcher.clearLocaleTestValue();
      VideoPlayerPlatform.instance = previous;
    }
  });
  for (final language in ['zh', 'en']) {
    testWidgets('uncertain export notice survives empty project $language', (
      tester,
    ) async {
      f = MobileVideoFixture();
      await tester.runAsync(() async {
        await f.init();
        f.state.dispose();
        f.state = _UncertainState();
        await f.state.ready;
      });
      final previous = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = FakeVideoPlatform();
      tester.binding.platformDispatcher.localeTestValue = Locale(language);
      await tester.binding.setSurfaceSize(const Size(360, 800));
      try {
        await tester.pumpWidget(BheMobileApp(appState: f.state));
        await tester.pump();
        expect(
          find.byKey(const ValueKey('uncertain-export-notice')),
          findsOneWidget,
        );
        expect(
          find.text(language == 'zh' ? '再次尝试停止' : 'Try stopping again'),
          findsOneWidget,
        );
        expect(
          find.text(language == 'zh' ? '检查停止状态' : 'Check status'),
          findsOneWidget,
        );
        final diagnostic = find.text(
          language == 'zh' ? '诊断与复制' : 'Diagnostics and copy',
        );
        await tester.tap(diagnostic);
        await tester.pumpAndSettle();
        expect(
          find.text(language == 'zh' ? '复制诊断信息' : 'Copy diagnostics'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => f.close());
        closed = true;
        await tester.binding.setSurfaceSize(null);
        tester.binding.platformDispatcher.clearLocaleTestValue();
        VideoPlayerPlatform.instance = previous;
      }
    });
  }
}
