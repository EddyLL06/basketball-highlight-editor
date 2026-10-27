import 'dart:async';
import 'dart:io';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:bhe_mobile/mobile_app_state.dart';
import 'package:bhe_mobile/native_analysis_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';

class _BothUncertainState extends MobileAppState {
  _BothUncertainState()
    : super(analysisEngine: const MobileAnalysisEngineUnavailable()) {
    checkingUncertainAnalysis = true;
    checkingUncertainExport = true;
  }
  @override
  bool get hasUncertainAnalysis => true;
  @override
  bool get hasUncertainExport => true;
}

class _UncertainState extends MobileAppState {
  _UncertainState()
    : super(analysisEngine: const MobileAnalysisEngineUnavailable());
  @override
  bool get hasUncertainAnalysis => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.bhe.bhe/mobile_analysis');
  const events = MethodChannel('com.bhe.bhe/mobile_analysis_progress');
  late MobileVideoFixture f;
  var closed = false;
  setUp(() {
    closed = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(events, (_) async => null);
  });
  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(events, null);
    if (!closed) await f.close();
  });
  test(
    'uncertainty survives new/open and only native confirmation releases it',
    () async {
      final started = Completer<void>(), result = Completer<Object?>();
      bool? active = true;
      var failStop = true, stops = 0;
      f = MobileVideoFixture();
      await f.init(
        engine: NativeAnalysisEngine(
          modelPreparer: () async => '/model',
          cancelTimeout: const Duration(milliseconds: 30),
        ),
        analysisStartupTimeout: const Duration(milliseconds: 35),
        analysisCancelTimeout: const Duration(milliseconds: 60),
      );
      final file = await f.file('original.mp4', 'original');
      f.state.project = f.project(file.path);
      expect(await f.state.updateCandidateNote('goal', 'keep'), isTrue);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'analyzeVideo') {
              started.complete();
              return result.future;
            }
            if (call.method == 'cancelAnalysis') {
              stops++;
              if (failStop) throw PlatformException(code: 'CANCEL_FAIL');
              return null;
            }
            if (call.method == 'isAnalysisActive') return active;
            return null;
          });
      final analysis = f.state.startAnalysis();
      await started.future;
      await analysis;
      expect(f.state.hasUncertainAnalysis, isTrue);
      final old = const ProjectPackageCodec().decode(
        await File('${f.data.path}/projects/A.json').readAsString(),
      );
      expect(old.candidates.single.note, 'keep');
      expect(f.state.canUndoReview, isTrue);
      await f.state.createNewProject();
      expect(f.state.hasUncertainAnalysis, isTrue);
      expect(f.state.uncertainAnalysisDiagnostic, isNotNull);
      await f.state.openProject('A');
      expect(f.state.hasUncertainAnalysis, isTrue);
      expect(f.state.canStartAnalysis, isFalse);
      expect(f.state.project.candidates.single.note, 'keep');
      active = null;
      expect(await f.state.checkUncertainAnalysis(), TaskStopStatus.unknown);
      expect(f.state.hasUncertainAnalysis, isTrue);
      active = true;
      expect(await f.state.checkUncertainAnalysis(), TaskStopStatus.running);
      expect(f.state.uncertainAnalysisStatus, '上次任务仍在运行，请稍候或再次尝试停止。');
      expect(
        await f.state.checkUncertainAnalysis(stopFirst: true),
        TaskStopStatus.unknown,
      );
      expect(f.state.hasUncertainAnalysis, isTrue);
      expect(f.state.uncertainAnalysisDiagnostic, isNotNull);
      failStop = false;
      expect(
        await f.state.checkUncertainAnalysis(stopFirst: true),
        TaskStopStatus.running,
      );
      expect(f.state.hasUncertainAnalysis, isTrue);
      active = false;
      expect(
        await f.state.checkUncertainAnalysis(stopFirst: true),
        TaskStopStatus.stopped,
      );
      expect(f.state.hasUncertainAnalysis, isFalse);
      expect(f.state.canStartAnalysis, isTrue);
      f.state.exporting = true;
      expect(f.state.canStartAnalysis, isFalse);
      f.state.exporting = false;
      expect(f.state.canStartAnalysis, isTrue);
      expect(stops, greaterThanOrEqualTo(3));
      result.complete({'candidates': <Object>[]});
      await pumpEventQueue();
      expect(f.state.project.candidates.single.note, 'keep');
    },
  );
  test('late result checks actual native worker before releasing', () async {
    final started = Completer<void>(), result = Completer<Object?>();
    var active = true;
    f = MobileVideoFixture();
    await f.init(
      engine: NativeAnalysisEngine(modelPreparer: () async => '/model'),
      analysisStartupTimeout: const Duration(milliseconds: 30),
    );
    final file = await f.file('original.mp4', 'original');
    f.state.project = f.project(file.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'analyzeVideo') {
            started.complete();
            return result.future;
          }
          if (call.method == 'isAnalysisActive') return active;
          return null;
        });
    final analysis = f.state.startAnalysis();
    await started.future;
    await analysis;
    result.complete({'candidates': <Object>[]});
    await pumpEventQueue();
    expect(f.state.hasUncertainAnalysis, isTrue);
    active = false;
    await Future<void>.delayed(const Duration(milliseconds: 650));
    expect(f.state.hasUncertainAnalysis, isFalse);
    expect(f.state.canStartAnalysis, isTrue);
  });
  for (final language in ['zh', 'en']) {
    testWidgets(
      'uncertain notice remains visible in an empty project $language',
      (tester) async {
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
            find.byKey(const ValueKey('uncertain-analysis-notice')),
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
          expect(
            find.text(language == 'zh' ? '诊断与复制' : 'Diagnostics and copy'),
            findsOneWidget,
          );
          expect(
            find.textContaining(
              language == 'zh' ? '强制停止 BHE' : 'force stop BHE',
            ),
            findsOneWidget,
          );
          final diagnostics = find.text(
            language == 'zh' ? '诊断与复制' : 'Diagnostics and copy',
          );
          final button = find
              .ancestor(of: diagnostics, matching: find.byType(TextButton))
              .first;
          expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
          await tester.tap(diagnostics);
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
      },
    );
  }
  for (final language in ['zh', 'en']) {
    testWidgets(
      'both uncertain tasks keep diagnostic actions available at 360dp $language',
      (tester) async {
        f = MobileVideoFixture();
        await tester.runAsync(() async {
          await f.init();
          f.state.dispose();
          f.state = _BothUncertainState();
          await f.state.ready;
        });
        final previous = VideoPlayerPlatform.instance;
        VideoPlayerPlatform.instance = FakeVideoPlatform();
        tester.binding.platformDispatcher.localeTestValue = Locale(language);
        tester.binding.platformDispatcher.textScaleFactorTestValue = 1.3;
        await tester.binding.setSurfaceSize(const Size(360, 800));
        try {
          await tester.pumpWidget(BheMobileApp(appState: f.state));
          await tester.pump();
          final exportCard = find.byKey(
            const ValueKey('uncertain-export-notice'),
          );
          final analysisCard = find.byKey(
            const ValueKey('uncertain-analysis-notice'),
          );
          Future<void> checkCard(Finder card, String label) async {
            await tester.scrollUntilVisible(card, 160);
            expect(
              find.descendant(of: card, matching: find.text(label)),
              findsOneWidget,
            );
            final diagnostic = find.descendant(
              of: card,
              matching: find.text(
                language == 'zh' ? '诊断与复制' : 'Diagnostics and copy',
              ),
            );
            final button = tester.widget<TextButton>(
              find
                  .ancestor(of: diagnostic, matching: find.byType(TextButton))
                  .first,
            );
            expect(button.onPressed, isNotNull);
            final stop = find.descendant(
              of: card,
              matching: find.text(
                language == 'zh' ? '再次尝试停止' : 'Try stopping again',
              ),
            );
            expect(
              tester
                  .widget<TextButton>(
                    find
                        .ancestor(of: stop, matching: find.byType(TextButton))
                        .first,
                  )
                  .onPressed,
              isNull,
            );
          }

          await checkCard(exportCard, language == 'zh' ? '导出' : 'Export');
          await checkCard(analysisCard, language == 'zh' ? '分析' : 'Analysis');
          final analysisText = language == 'zh'
              ? '上次分析尚未确认停止，暂时不能开始新分析。'
              : 'The previous analysis may still be running. A new analysis cannot start yet.';
          expect(
            find.descendant(
              of: analysisCard,
              matching: find.text(analysisText),
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() => f.close());
          closed = true;
          await tester.binding.setSurfaceSize(null);
          tester.binding.platformDispatcher.clearLocaleTestValue();
          tester.binding.platformDispatcher.clearTextScaleFactorTestValue();
          VideoPlayerPlatform.instance = previous;
        }
      },
    );
  }
}
