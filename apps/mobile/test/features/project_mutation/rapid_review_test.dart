import 'dart:async';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';
import '../../support/wait_project_writes.dart';

void main() {
  late MobileVideoFixture f;
  setUp(() async {
    f = MobileVideoFixture();
    await f.init();
  });
  tearDown(() => f.close());
  testWidgets(
    'rapid review advances and queues both clicks while save is blocked',
    (tester) async {
      final platform = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = FakeVideoPlatform();
      await tester.binding.setSurfaceSize(const Size(360, 800));
      final entered = Completer<void>(), release = Completer<void>();
      try {
        final base = f.project('${f.root.path}/missing.mp4');
        f.state.project = base.copyWith(
          candidates: const [
            Candidate(id: 'one', startMs: 0, endMs: 1000, eventMs: 500),
            Candidate(id: 'two', startMs: 1000, endMs: 2000, eventMs: 1500),
            Candidate(id: 'three', startMs: 2000, endMs: 3000, eventMs: 2500),
          ],
        );
        await tester.pumpWidget(BheMobileApp(appState: f.state));
        await tester.pump();
        final context = tester.element(find.byType(Scaffold).first);
        final l10n = Localizations.of<BheLocalizations>(
          context,
          BheLocalizations,
        )!;
        final review = find.text(l10n.reviewCount(3));
        await tester.ensureVisible(review);
        await tester.pump();
        await tester.tap(review);
        await tester.pump();
        var first = true;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async {
                if (first) {
                  first = false;
                  entered.complete();
                  await release.future;
                }
                return f.root.path;
              },
            );
        await tester.tap(find.text(l10n.text('不选')));
        await tester.pump();
        for (var i = 0; i < 100 && !entered.isCompleted; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      }
      expect(entered.isCompleted, isTrue);
        final clock = Stopwatch()..start();
        await tester.tap(find.text(l10n.text('选中')));
        await tester.pump();
        clock.stop();
        expect(release.isCompleted, isFalse);
        release.complete();
        await waitProjectWrites(tester, f.state.pendingProjectWrites);
        expect(
          f.state.project.candidates[0].selection,
          CandidateSelection.excluded,
        );
        expect(f.state.project.candidates[1].reviewed, isTrue);
        expect(f.state.project.candidates[2].reviewed, isFalse);
        expect(tester.takeException(), isNull);
        debugPrint(
          'Two review taps while save blocked: second tap ${clock.elapsedMilliseconds}ms',
        );
      } finally {
        if (!release.isCompleted) release.complete();
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => pumpEventQueue());
        VideoPlayerPlatform.instance = platform;
        await tester.binding.setSurfaceSize(null);
      }
    },
  );
}
