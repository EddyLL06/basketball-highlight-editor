import 'package:bhe_core/bhe_core.dart';
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
          'four source-recovery pages fit $width $brightness $language at 1.3x',
          (tester) async {
            await tester.binding.setSurfaceSize(Size(width, 800));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            tester.binding.platformDispatcher.localeTestValue = Locale(
              language,
            );
            tester.binding.platformDispatcher.textScaleFactorTestValue = 1.3;
            addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
            addTearDown(
              tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
            );
            final previous = VideoPlayerPlatform.instance;
            VideoPlayerPlatform.instance = FakeVideoPlatform();
            try {
              fixture.state.project = fixture.project(
                '${fixture.root.path}/missing.mp4',
              );
              fixture.state.markVideoFailure(VideoSourceFailure.missing);
              await tester.pumpWidget(BheMobileApp(appState: fixture.state));
              await tester.runAsync(() => pumpEventQueue());
              await tester.pump();
              if (brightness == Brightness.light) {
                tester
                    .widget<PopupMenuButton<String>>(
                      find.byType(PopupMenuButton<String>),
                    )
                    .onSelected!('theme');
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 300));
              }
              void checkNotice() {
                expect(find.byType(VideoSourceNotice), findsOneWidget);
                expect(
                  Theme.of(
                    tester.element(find.byType(VideoSourceNotice)),
                  ).brightness,
                  brightness,
                );
                final error = tester.takeException();
                if (error != null) debugPrint(error.toString());
                expect(error, isNull);
              }

              checkNotice();
              final l10n = Localizations.of<BheLocalizations>(
                tester.element(find.byType(VideoSourceNotice)),
                BheLocalizations,
              )!;
              final review = find.text(l10n.reviewCount(1));
              await tester.ensureVisible(review);
              await tester.pump();
              await tester.tap(review);
              await tester.pump();
              await tester.runAsync(() => pumpEventQueue());
              await tester.pump();
              expect(find.byType(VideoSourcePanel), findsOneWidget);
              checkNotice();
              await tester.tap(find.byTooltip(l10n.navExport).first);
              await tester.pump();
              await tester.scrollUntilVisible(
                find.byType(VideoSourceNotice),
                250,
              );
              checkNotice();
              fixture.state.analysing = true;
              fixture.state.stage = AnalysisStage.validateInput;
              fixture.state.markVideoFailure(VideoSourceFailure.missing);
              await tester.pump();
              await tester.scrollUntilVisible(
                find.byType(VideoSourceNotice),
                250,
              );
              checkNotice();
            } finally {
              await tester.pumpWidget(const SizedBox());
              await tester.runAsync(() => pumpEventQueue());
              VideoPlayerPlatform.instance = previous;
            }
          },
        );
      }
    }
  }
}
