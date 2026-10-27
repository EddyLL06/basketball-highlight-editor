import 'dart:async';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:file_picker/file_picker.dart';
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
  for (final situation in ['picker', 'barrier', 'failedReview']) {
    testWidgets('review and settings during $situation', (tester) async {
      final previous = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = FakeVideoPlatform();
      tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
      await tester.binding.setSurfaceSize(const Size(360, 800));
      final entered = Completer<void>(), release = Completer<void>();
      final picker = Completer<FilePickerResult?>();
      try {
        f.state.project = f
            .project('${f.root.path}/missing.mp4')
            .copyWith(
              candidates: const [
                Candidate(id: 'one', startMs: 0, endMs: 1000, eventMs: 500),
                Candidate(id: 'two', startMs: 1000, endMs: 2000, eventMs: 1500),
                Candidate(
                  id: 'three',
                  startMs: 2000,
                  endMs: 3000,
                  eventMs: 2500,
                ),
              ],
            );
        await tester.pumpWidget(BheMobileApp(appState: f.state));
        await tester.pump();
        final l10n = Localizations.of<BheLocalizations>(
          tester.element(find.byType(Scaffold).first),
          BheLocalizations,
        )!;
        await tester.ensureVisible(find.text(l10n.reviewCount(3)));
        await tester.pump();
        await tester.tap(find.text(l10n.reviewCount(3)));
        await tester.pump();
        final exclude = find.text(l10n.text('不选')).last;
        if (situation == 'picker') {
          f.picker.pick = () {
            entered.complete();
            return picker.future;
          };
          final importing = f.state.importProject();
          await tester.pump();
          expect(entered.isCompleted, isTrue);
          expect(f.state.projectTransitioning, isFalse);
          expect(
            find.byKey(const ValueKey('project-transition-notice')),
            findsNothing,
          );
          await tester.tap(exclude);
          await tester.pump();
          await tester.tap(exclude);
          await tester.pump();
          final settings = f.state.updateSettings(
            f.state.project.settings.copyWith(startMs: 123),
            fields: {'startMs'},
          );
          await waitProjectWrites(tester, f.state.pendingProjectWrites);
          expect(await tester.runAsync(() => settings), isTrue);
          expect(f.state.project.candidates[0].reviewed, isTrue);
          expect(f.state.project.candidates[1].reviewed, isTrue);
          expect(f.state.project.candidates[2].reviewed, isFalse);
          expect(f.state.project.settings.startMs, 123);
          picker.complete(null);
          await tester.runAsync(() => importing);
        } else {
          var first = true;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                (_) async {
                  if (first) {
                    first = false;
                    entered.complete();
                    await release.future;
                    if (situation == 'failedReview') {
                      throw PlatformException(code: 'save_failed');
                    }
                  }
                  return f.root.path;
                },
              );
          await tester.tap(exclude);
          await tester.pump();
          for (var i = 0; i < 100 && !entered.isCompleted; i++) {
            await tester.pump();
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          expect(entered.isCompleted, isTrue);
          if (situation == 'barrier') {
            final switching = f.state.createNewProject();
            await tester.pump();
            expect(
              find.byKey(const ValueKey('project-transition-notice')),
              findsOneWidget,
            );
            await tester.tap(exclude, warnIfMissed: false);
            await tester.pump();
            expect(
              await tester.runAsync(
                () => f.state.updateSettings(
                  f.state.project.settings.copyWith(startMs: 123),
                  fields: {'startMs'},
                ),
              ),
              isFalse,
            );
            expect(f.state.project.candidates[1].reviewed, isFalse);
            release.complete();
            await waitProjectWrites(tester, switching);
            await tester.pump();
            expect(
              find.byKey(const ValueKey('project-transition-notice')),
              findsNothing,
            );
          } else {
            release.complete();
            await waitProjectWrites(tester, f.state.pendingProjectWrites);
            expect(f.state.project.candidates[0].reviewed, isFalse);
            expect(
              find.byKey(const ValueKey('review-feedback-action')),
              findsOneWidget,
            );
            await tester.tap(exclude);
            await tester.pump();
            await waitProjectWrites(tester, f.state.pendingProjectWrites);
            expect(f.state.project.candidates[0].reviewed, isTrue);
            expect(f.state.project.candidates[1].reviewed, isFalse);
          }
        }
        expect(tester.takeException(), isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        if (!picker.isCompleted) picker.complete(null);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() => pumpEventQueue());
        VideoPlayerPlatform.instance = previous;
        tester.binding.platformDispatcher.clearLocaleTestValue();
        await tester.binding.setSurfaceSize(null);
      }
    });
  }
}
