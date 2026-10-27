import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/features/video_source/video_source_failure.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  late MobileVideoFixture fixture;
  setUp(() async {
    fixture = MobileVideoFixture();
    await fixture.init();
  });
  tearDown(() => fixture.close());

  for (final width in [360.0, 412.0]) {
    for (final brightness in Brightness.values) {
      for (final language in ['zh', 'en']) {
        testWidgets(
          'ROI failure actions fit $width $brightness $language at 1.3x',
          (tester) async {
            await tester.binding.setSurfaceSize(Size(width, 800));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            var recovered = false;
            var returned = false;
            for (final failure in [
              VideoSourceFailure.missing,
              VideoSourceFailure.unplayable,
            ]) {
              await tester.pumpWidget(
                MaterialApp(
                  locale: Locale(language),
                  theme: bheTheme(brightness),
                  localizationsDelegates:
                      BheLocalizations.localizationsDelegates,
                  supportedLocales: BheLocalizations.supportedLocales,
                  builder: (_, child) => MediaQuery(
                    data: MediaQueryData(
                      size: Size(width, 800),
                      textScaler: const TextScaler.linear(1.3),
                    ),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: Padding(
                      padding: const EdgeInsets.all(16),
                      child: RoiPreviewFailure(
                        failure: failure,
                        onRelink: () => recovered = true,
                        onBack: () => returned = true,
                      ),
                    ),
                  ),
                ),
              );
              await tester.pump();
              expect(tester.takeException(), isNull);
              final buttons = find.byType(TextButton);
              expect(buttons, findsNWidgets(failure.canRelink ? 3 : 2));
              for (final button in buttons.evaluate()) {
                expect(
                  tester.getSize(find.byWidget(button.widget)).height,
                  greaterThanOrEqualTo(48),
                );
              }
              if (language == 'en') {
                for (final text in tester.widgetList<Text>(find.byType(Text))) {
                  expect(
                    text.data ?? '',
                    isNot(matches(RegExp(r'[\u4e00-\u9fff]'))),
                  );
                }
              }
              expect(
                find.byKey(const ValueKey('roi-feedback')),
                findsOneWidget,
              );
              if (failure.canRelink) {
                await tester.tap(find.byKey(const ValueKey('roi-relink')));
              }
              await tester.tap(find.byKey(const ValueKey('roi-back')));
            }
            expect(recovered, isTrue);
            expect(returned, isTrue);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  testWidgets(
    'missing video editor offers recovery and keeps existing regions',
    (tester) async {
      final previous = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = FakeVideoPlatform();
      tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      try {
        fixture.state.project = fixture.project(
          '${fixture.root.path}/missing.mp4',
        );
        final original = fixture.state.project;
        await tester.pumpWidget(BheMobileApp(appState: fixture.state));
        await tester.pump();
        final setting = find.text('投篮分析区与篮网区');
        await tester.ensureVisible(setting);
        await tester.pump();
        await tester.tap(setting);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.byType(RoiPreviewFailure), findsOneWidget);
        expect(fixture.state.videoMissing, isTrue);
        expect(fixture.state.project.hoopRoi, original.hoopRoi);
        fixture.choose(null);
        await tester.tap(
          find.descendant(
            of: find.byType(RoiPreviewFailure),
            matching: find.text('重新选择视频'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump();
        expect(find.byType(RoiPreviewFailure), findsNothing);
        expect(fixture.state.project.hoopRoi, original.hoopRoi);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => pumpEventQueue());
        VideoPlayerPlatform.instance = previous;
      }
    },
  );
}
