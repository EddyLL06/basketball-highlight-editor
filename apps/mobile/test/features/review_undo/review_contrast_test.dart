import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
}

void main() {
  late MobileVideoFixture f;
  setUp(() async {
    f = MobileVideoFixture();
    await f.init();
  });
  tearDown(() => f.close());
  for (final brightness in Brightness.values) {
    for (final language in ['zh', 'en']) {
      testWidgets('save failure SnackBar fits $brightness $language', (
        tester,
      ) async {
        final previous = VideoPlayerPlatform.instance;
        VideoPlayerPlatform.instance = FakeVideoPlatform();
        tester.binding.platformDispatcher.localeTestValue = Locale(language);
        tester.binding.platformDispatcher.textScaleFactorTestValue = 1.3;
        await tester.binding.setSurfaceSize(const Size(360, 800));
        try {
          f.state.project = f.project('${f.root.path}/missing.mp4');
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
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                (_) async =>
                    throw PlatformException(code: 'injected_contrast_failure'),
              );
          await tester.runAsync(
            () => f.state.toggleCandidate('goal', CandidateSelection.excluded),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          final snack = find.byKey(const ValueKey('review-save-failure'));
          expect(snack, findsOneWidget);
          final widget = tester.widget<SnackBar>(snack);
          expect(widget.behavior, SnackBarBehavior.floating);
          expect(
            find.byKey(const ValueKey('review-feedback-action')),
            findsOneWidget,
          );
          final text = find.text(l10n.text('保存失败，请重试'));
          expect(text, findsOneWidget);
          final textElement = tester.element(text);
          final foreground = DefaultTextStyle.of(textElement).style.color!;
          final background = Theme.of(textElement).colorScheme.inverseSurface;
          expect(contrast(foreground, background), greaterThanOrEqualTo(4.5));
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
