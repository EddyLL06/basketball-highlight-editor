import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  late MobileVideoFixture f;
  setUp(() async {
    f = MobileVideoFixture();
    await f.init();
  });
  tearDown(() => f.close());
  for (final width in [360.0, 412.0]) {
    for (final brightness in Brightness.values) {
      for (final language in ['zh', 'en']) {
        testWidgets('group management fits $width $brightness $language', (
          tester,
        ) async {
          final previous = VideoPlayerPlatform.instance;
          VideoPlayerPlatform.instance = FakeVideoPlatform();
          tester.binding.platformDispatcher.localeTestValue = Locale(language);
          tester.binding.platformDispatcher.textScaleFactorTestValue = 1.3;
          await tester.binding.setSurfaceSize(Size(width, 800));
          try {
            f.state.project = f.project('${f.root.path}/missing.mp4');
            expect(
              await tester.runAsync(() => f.state.savePlayerGroup('Team')),
              isTrue,
            );
            expect(
              await tester.runAsync(
                () => f.state.setDefaultPlayerGroup('Team'),
              ),
              isTrue,
            );
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
            await tester.ensureVisible(find.text(l10n.reviewCount(1)));
            await tester.pump();
            await tester.tap(find.text(l10n.reviewCount(1)));
            await tester.pump();
            await tester.tap(find.byTooltip(l10n.text('球员：Alice')));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            await tester.tap(find.text(l10n.text('球员分组')).last);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            expect(
              find.byKey(const ValueKey('player-group-Team')),
              findsOneWidget,
            );
            expect(find.text(l10n.text('默认')), findsOneWidget);
            expect(
              tester
                  .getSize(find.byKey(const ValueKey('player-group-menu-Team')))
                  .height,
              greaterThanOrEqualTo(48),
            );
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
  testWidgets('replacement and deletion require explicit confirmation', (
    tester,
  ) async {
    final previous = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = FakeVideoPlatform();
    tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
    await tester.binding.setSurfaceSize(const Size(360, 800));
    try {
      f.state.project = f.project('${f.root.path}/missing.mp4');
      expect(
        await tester.runAsync(() => f.state.savePlayerGroup('Team')),
        isTrue,
      );
      await tester.pumpWidget(BheMobileApp(appState: f.state));
      await tester.pump();
      final l10n = Localizations.of<BheLocalizations>(
        tester.element(find.byType(Scaffold).first),
        BheLocalizations,
      )!;
      await tester.ensureVisible(find.text(l10n.reviewCount(1)));
      await tester.pump();
      await tester.tap(find.text(l10n.reviewCount(1)));
      await tester.pump();
      await tester.tap(find.byTooltip(l10n.text('球员：Alice')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text(l10n.text('球员分组')).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text(l10n.text('把当前球员存为分组')).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField).last, 'Team');
      await tester.tap(find.text(l10n.text('保存')).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(l10n.text('已有同名分组，是否替换？')), findsOneWidget);
      await tester.tap(find.text(l10n.text('取消')).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(f.state.playerGroups.single.name, 'Team');
      await tester.tap(find.byKey(const ValueKey('player-group-menu-Team')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text(l10n.text('删除')).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(l10n.text('确认删除分组？')), findsOneWidget);
      await tester.tap(find.text(l10n.text('删除')).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(f.state.playerGroups, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => pumpEventQueue());
      VideoPlayerPlatform.instance = previous;
      tester.binding.platformDispatcher.clearLocaleTestValue();
      await tester.binding.setSurfaceSize(null);
    }
  });
}
