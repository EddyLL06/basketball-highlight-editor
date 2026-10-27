import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  late MobileVideoFixture f;
  late String videoPath;
  setUp(() async {
    f = MobileVideoFixture();
    await f.init();
    videoPath = (await f.file('original.mp4', 'original')).path;
  });
  tearDown(() => f.close());
  for (final width in [360.0, 412.0]) {
    for (final brightness in Brightness.values) {
      for (final language in ['zh', 'en']) {
        testWidgets('roster confirmation fits $width $brightness $language', (
          tester,
        ) async {
          final previous = VideoPlayerPlatform.instance;
          VideoPlayerPlatform.instance = FakeVideoPlatform();
          await tester.binding.setSurfaceSize(Size(width, 800));
          tester.binding.platformDispatcher.localeTestValue = Locale(language);
          tester.binding.platformDispatcher.textScaleFactorTestValue = 1.3;
          try {
            f.state.project = f.project(videoPath).copyWith(players: []);
            f.state.playerGroups = [
              (name: 'Team', players: ['Alice', 'Bob', 'Carol']),
            ];
            f.state.defaultPlayerGroupName = 'Team';
            await tester.pumpWidget(BheMobileApp(appState: f.state));
            await tester.pump();
            if (brightness == Brightness.light) {
              tester
                  .widget<PopupMenuButton<String>>(
                    find.byType(PopupMenuButton<String>),
                  )
                  .onSelected!('theme');
              await tester.pump();
            }
            final l10n = Localizations.of<BheLocalizations>(
              tester.element(find.byType(Scaffold).first),
              BheLocalizations,
            )!;
            await tester.ensureVisible(
              find.byKey(const ValueKey('start-analysis')),
            );
            await tester.pump();
            await tester.tap(find.byKey(const ValueKey('start-analysis')));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            expect(find.text(l10n.text('球员名单')), findsOneWidget);
            expect(
              find.byKey(const ValueKey('roster-player-Alice')),
              findsOneWidget,
            );
            if (find
                .byKey(const ValueKey('roster-player-Bob'))
                .evaluate()
                .isEmpty) {
              await tester.drag(
                find
                    .descendant(
                      of: find.byType(DraggableScrollableSheet),
                      matching: find.byType(ListView),
                    )
                    .last,
                const Offset(0, -220),
              );
              await tester.pump();
            }
            await tester.ensureVisible(
              find.byKey(const ValueKey('roster-player-Bob')),
            );
            await tester.pump();
            final bob = tester.widget<CheckboxListTile>(
              find.byKey(const ValueKey('roster-player-Bob')),
            );
            expect(bob.value, isTrue);
            await tester.tap(find.byKey(const ValueKey('roster-player-Bob')));
            await tester.pump();
            expect(f.state.rosterSelection.orderedPlayers, ['Alice', 'Carol']);
            await tester.tap(find.text(l10n.cancel).last);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            expect(f.state.project.players, isEmpty);
            expect(f.state.rosterSelection.orderedPlayers, ['Alice', 'Carol']);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(() => pumpEventQueue());
            VideoPlayerPlatform.instance = previous;
            tester.binding.platformDispatcher.clearLocaleTestValue();
            tester.binding.platformDispatcher.clearTextScaleFactorTestValue();
            await tester.binding.setSurfaceSize(null);
          }
        });
      }
    }
  }
  testWidgets('default can be set and cleared from confirmation', (
    tester,
  ) async {
    final previous = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = FakeVideoPlatform();
    tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
    await tester.binding.setSurfaceSize(const Size(360, 800));
    try {
      f.state.project = f.project(videoPath).copyWith(players: []);
      f.state.playerGroups = [
        (name: 'Team', players: ['Alice']),
      ];
      f.state.rosterSelection.choose('Team', ['Alice']);
      await tester.pumpWidget(BheMobileApp(appState: f.state));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('start-analysis')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('start-analysis')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.ensureVisible(find.byKey(const ValueKey('roster-default')));
      await tester.tap(find.byKey(const ValueKey('roster-default')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(f.state.defaultPlayerGroupName, 'Team');
      expect(find.text('取消默认'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('roster-default')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(f.state.defaultPlayerGroupName, isNull);
      expect(find.text('设为默认'), findsOneWidget);
      expect(f.state.project.players, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => pumpEventQueue());
      VideoPlayerPlatform.instance = previous;
      tester.binding.platformDispatcher.clearLocaleTestValue();
      await tester.binding.setSurfaceSize(null);
    }
  });
}
