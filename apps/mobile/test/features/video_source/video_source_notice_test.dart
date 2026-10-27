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
          '$width $brightness $language notices scale to 1.3 without overflow',
          (tester) async {
            await tester.binding.setSurfaceSize(Size(width, 800));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            for (final failure in VideoSourceFailure.values) {
              fixture.state.markVideoFailure(failure);
              await tester.pumpWidget(
                MaterialApp(
                  locale: Locale(language),
                  localizationsDelegates:
                      BheLocalizations.localizationsDelegates,
                  supportedLocales: BheLocalizations.supportedLocales,
                  theme: bheTheme(brightness),
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
                      child: VideoSourcePanel(
                        state: fixture.state,
                        child: const SizedBox(),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pump();
              expect(tester.takeException(), isNull);
              final button = find.byKey(const ValueKey('video-relink'));
              expect(button, failure.canRelink ? findsOneWidget : findsNothing);
              if (failure.canRelink) {
                final size = tester.getSize(button);
                expect(size.height, greaterThanOrEqualTo(48));
                expect(size.width, greaterThanOrEqualTo(48));
              }
              if (language == 'en') {
                for (final text in tester.widgetList<Text>(find.byType(Text))) {
                  expect(
                    text.data ?? '',
                    isNot(matches(RegExp(r'[\u4e00-\u9fff]'))),
                  );
                }
              }
            }
            fixture.state.relinkingVideo = true;
            fixture.state.markVideoFailure(VideoSourceFailure.missing);
            await tester.pump();
            expect(
              tester
                  .widget<TextButton>(
                    find.byKey(const ValueKey('video-relink')),
                  )
                  .onPressed,
              isNull,
            );
            expect(
              tester
                  .getSize(find.byKey(const ValueKey('video-relink-cancel')))
                  .height,
              greaterThanOrEqualTo(48),
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }

  testWidgets(
    'review shows missing notice and replaces its player after recovery',
    (tester) async {
      tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      final platform = FakeVideoPlatform();
      final previous = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      fixture.state.project = fixture.project(
        '${fixture.root.path}/missing.mp4',
      );
      fixture.state.markVideoFailure(VideoSourceFailure.missing);
      await tester.pumpWidget(BheMobileApp(appState: fixture.state));
      await tester.pump();
      await tester.ensureVisible(find.text('审核 1'));
      await tester.pump();
      await tester.tap(find.text('审核 1'));
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(find.byType(VideoSourcePanel), findsOneWidget);
      expect(find.text(VideoSourceFailure.missing.message), findsOneWidget);
      await tester.runAsync(() async {
        fixture.choose(await fixture.file('recovered.mp4', 'original'));
        await fixture.state.relinkVideo();
      });
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      final path = fixture.state.project.video!.path;
      expect(
        platform.sources.values.any(
          (source) => source.uri == Uri.file(path).toString(),
        ),
        isTrue,
      );
      expect(find.text(VideoSourceFailure.missing.message), findsNothing);
      final beforeReload = platform.sources.length;
      fixture.state.markVideoFailure(VideoSourceFailure.mismatch);
      await tester.pump();
      await tester.runAsync(() async {
        fixture.choose(
          await fixture.file('same_path_replacement.mp4', 'original'),
        );
        await fixture.state.relinkVideo();
      });
      expect(fixture.state.project.video!.path, path);
      await tester.pump();
      await tester.runAsync(() async {
        await pumpEventQueue();
      });
      await tester.pump();
      expect(platform.sources.length, greaterThan(beforeReload));
      expect(platform.disposed, isNotEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
