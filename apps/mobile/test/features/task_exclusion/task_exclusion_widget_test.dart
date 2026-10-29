import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:bhe_mobile/mobile_app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';

class _UncertainAnalysisState extends MobileAppState {
  _UncertainAnalysisState()
    : super(analysisEngine: const MobileAnalysisEngineUnavailable());
  @override
  bool get hasUncertainAnalysis => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final language in ['zh', 'en']) {
    for (final analysing in [false, true]) {
      testWidgets(
        '${analysing ? 'analysis' : 'export'} explains blocking in $language',
        (tester) async {
          final f = MobileVideoFixture();
          await tester.runAsync(() async {
            await f.init();
            final file = await f.file('original.mp4', 'original');
            f.state.project = f.project(file.path);
            f.state.analysing = analysing;
            f.state.exporting = !analysing;
          });
          final previous = VideoPlayerPlatform.instance;
          VideoPlayerPlatform.instance = FakeVideoPlatform();
          tester.binding.platformDispatcher.localeTestValue = Locale(language);
          tester.binding.platformDispatcher.textScaleFactorTestValue = 1.3;
          await tester.binding.setSurfaceSize(const Size(360, 800));
          try {
            await tester.pumpWidget(BheMobileApp(appState: f.state));
            await tester.pump();
            final text = analysing
                ? (language == 'zh'
                      ? '正在分析，请等待分析结束。'
                      : 'Analysis is running. Wait for it to finish.')
                : (language == 'zh'
                      ? '正在导出，请等待导出结束。'
                      : 'Export is running. Wait for it to finish.');
            final notice = find.text(text);
            await tester.scrollUntilVisible(notice, 150);
            expect(notice, findsOneWidget);
            if (!analysing) {
              final button = tester.widget<FilledButton>(
                find.byKey(const ValueKey('start-analysis')),
              );
              expect(button.onPressed, isNull);
            }
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(() => f.close());
            await tester.binding.setSurfaceSize(null);
            tester.binding.platformDispatcher.clearLocaleTestValue();
            tester.binding.platformDispatcher.clearTextScaleFactorTestValue();
            VideoPlayerPlatform.instance = previous;
          }
        },
      );
    }
  }
  testWidgets('uncertain analysis explains why export is disabled', (
    tester,
  ) async {
    final f = MobileVideoFixture();
    await tester.runAsync(() async {
      await f.init();
      final file = await f.file('original.mp4', 'original');
      f.state.dispose();
      f.state = _UncertainAnalysisState();
      await f.state.ready;
      f.state.project = f.project(file.path);
    });
    final previous = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = FakeVideoPlatform();
    tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
    await tester.binding.setSurfaceSize(const Size(360, 800));
    try {
      await tester.pumpWidget(BheMobileApp(appState: f.state));
      await tester.pump();
      await tester.tap(find.byTooltip('导出'));
      await tester.pump();
      expect(find.text('上次分析尚未确认停止，暂时不能导出。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('uncertain-analysis-notice')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => f.close());
      await tester.binding.setSurfaceSize(null);
      tester.binding.platformDispatcher.clearLocaleTestValue();
      VideoPlayerPlatform.instance = previous;
    }
  });
}
