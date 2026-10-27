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
      for (final failure in [false, true]) {
        testWidgets(
          'review notice text and action contrast on black and white frames: $brightness $language failure=$failure',
          (tester) async {
            final previous = VideoPlayerPlatform.instance;
            VideoPlayerPlatform.instance = FakeVideoPlatform();
            tester.binding.platformDispatcher.localeTestValue = Locale(
              language,
            );
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
              if (failure) {
                TestDefaultBinaryMessengerBinding
                    .instance
                    .defaultBinaryMessenger
                    .setMockMethodCallHandler(
                      const MethodChannel('plugins.flutter.io/path_provider'),
                      (_) async => throw PlatformException(
                        code: 'injected_contrast_failure',
                      ),
                    );
              }
              await tester.runAsync(
                () => f.state.toggleCandidate(
                  'goal',
                  CandidateSelection.excluded,
                ),
              );
              await tester.pump();
              final surface = find
                  .byKey(const ValueKey('review-notice-surface'))
                  .last;
              final surfaceColor = tester.widget<Material>(surface).color!;
              final tintContainer = tester.widget<Container>(
                find
                    .descendant(
                      of: surface,
                      matching: find.byWidgetPredicate(
                        (widget) =>
                            widget is Container &&
                            widget.decoration is BoxDecoration,
                      ),
                    )
                    .first,
              );
              final tint = (tintContainer.decoration! as BoxDecoration).color!;
              final text = tester.widget<Text>(
                find.text(l10n.text(failure ? '保存失败，请重试' : '已排除')).last,
              );
              final foreground = text.style!.color!;
              final action = tester.widget<TextButton>(
                find
                    .byKey(
                      ValueKey(
                        failure
                            ? 'review-feedback-action'
                            : 'review-undo-action',
                      ),
                    )
                    .last,
              );
              final actionColor = action.style!.foregroundColor!.resolve(
                <WidgetState>{},
              )!;
              expect(surfaceColor.a, 1.0);
              for (final frame in [Colors.black, Colors.white]) {
                final background = Color.alphaBlend(
                  tint,
                  Color.alphaBlend(surfaceColor, frame),
                );
                expect(
                  contrast(foreground, background),
                  greaterThanOrEqualTo(4.5),
                );
                expect(
                  contrast(actionColor, background),
                  greaterThanOrEqualTo(4.5),
                );
              }
              expect(tester.takeException(), isNull);
            } finally {
              await tester.pumpWidget(const SizedBox());
              await tester.runAsync(() => pumpEventQueue());
              VideoPlayerPlatform.instance = previous;
              tester.binding.platformDispatcher.clearLocaleTestValue();
              await tester.binding.setSurfaceSize(null);
            }
          },
        );
      }
    }
  }
}
