import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/features/video_source/video_source_failure.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

void main() {
  testWidgets('review save failure does not hide an existing video failure', (
    tester,
  ) async {
    final f = MobileVideoFixture();
    await tester.runAsync(f.init);
    tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
    await tester.binding.setSurfaceSize(const Size(360, 800));
    try {
      f.state.project = f.project('${f.root.path}/missing.mp4');
      f.state.markVideoFailure(VideoSourceFailure.missing);
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
      expect(find.byKey(const ValueKey('video-source-notice')), findsOneWidget);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => throw PlatformException(code: 'review_write_failed'),
          );
      await tester.runAsync(
        () => f.state.toggleCandidate('goal', CandidateSelection.excluded),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('video-source-notice')), findsOneWidget);
      expect(find.text(VideoSourceFailure.missing.message), findsOneWidget);
      expect(find.byKey(const ValueKey('review-save-failure')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('review-feedback-action')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(f.close);
      tester.binding.platformDispatcher.clearLocaleTestValue();
      await tester.binding.setSurfaceSize(null);
    }
  });
}
