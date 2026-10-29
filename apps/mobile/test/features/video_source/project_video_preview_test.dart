import 'package:bhe_mobile/features/diagnostics/mobile_diagnostics.dart';
import 'package:bhe_l10n/bhe_l10n.dart';
import 'package:bhe_mobile/clip_range_editor.dart';
import 'package:bhe_mobile/features/video_source/video_source_failure.dart';
import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  late MobileVideoFixture fixture;
  late FakeVideoPlatform platform;
  late VideoPlayerPlatform previous;
  setUp(() async {
    fixture = MobileVideoFixture();
    await fixture.init();
    previous = VideoPlayerPlatform.instance;
    platform = FakeVideoPlatform();
    VideoPlayerPlatform.instance = platform;
  });
  tearDown(() async {
    await fixture.close();
    VideoPlayerPlatform.instance = previous;
  });

  Future<void> mount(WidgetTester tester) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    await tester.pumpWidget(BheMobileApp(appState: fixture.state));
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => pumpEventQueue());
  }

  testWidgets(
    'project preview initializes again when recovery restores exactly the same path',
    (tester) async {
      final path = await tester.runAsync(() async {
        final source = await fixture.file(
          'BHE Mobile/videos/A/source.mp4',
          'original',
        );
        final canonical = await source.resolveSymbolicLinks();
        await source.delete();
        return canonical;
      });
      fixture.state.project = fixture.project(path!);
      fixture.state.markVideoFailure(VideoSourceFailure.missing);
      platform.failInitialize = true;
      await mount(tester);
      try {
        expect(find.byType(VideoPlayer), findsNothing);
        platform.failInitialize = false;
        await tester.runAsync(() async {
          fixture.choose(await fixture.file('recovered.mp4', 'original'));
          await fixture.state.relinkVideo();
        });
        expect(fixture.state.project.video!.path, path);
        await tester.pump();
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump();
        expect(find.byType(VideoPlayer), findsOneWidget);
        final player = tester
            .widget<VideoPlayer>(find.byType(VideoPlayer))
            .controller;
        expect(player.value.isInitialized, isTrue);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await unmount(tester);
      }
    },
  );

  testWidgets(
    'known missing source has static unavailable preview and disabled analysis',
    (tester) async {
      fixture.state.project = fixture.project(
        '${fixture.root.path}/missing.mp4',
      );
      fixture.state.markVideoFailure(VideoSourceFailure.missing);
      await mount(tester);
      try {
        expect(find.text('视频不可用'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byType(VideoPlayer), findsNothing);
        expect(platform.sources, isEmpty);
        final analyze = find.widgetWithText(FilledButton, '重新分析');
        await tester.ensureVisible(analyze);
        await tester.pump();
        expect(tester.widget<FilledButton>(analyze).onPressed, isNull);
        expect(tester.takeException(), isNull);
      } finally {
        await unmount(tester);
      }
    },
  );
  testWidgets(
    'healthy preview reloads on source revision even when path and availability stay the same',
    (tester) async {
      final path = await tester.runAsync(
        () async => (await fixture.file(
          'BHE Mobile/videos/A/source.mp4',
          'original',
        )).resolveSymbolicLinks(),
      );
      fixture.state.project = fixture.project(path!);
      await mount(tester);
      try {
        final old = tester
            .widget<VideoPlayer>(find.byType(VideoPlayer))
            .controller;
        final revision = fixture.state.videoSourceRevision;
        await tester.runAsync(() async {
          fixture.choose(await fixture.file('replacement.mp4', 'original'));
          await fixture.state.relinkVideo();
        });
        expect(fixture.state.project.video!.path, path);
        expect(fixture.state.videoSourceFailure, isNull);
        expect(fixture.state.videoSourceRevision, greaterThan(revision));
        await tester.pump();
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump();
        final next = tester
            .widget<VideoPlayer>(find.byType(VideoPlayer))
            .controller;
        expect(next.playerId, isNot(old.playerId));
        expect(next.value.isInitialized, isTrue);
        expect(platform.disposed, contains(old.playerId));
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('start-analysis')),
              )
              .onPressed,
          isNotNull,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await unmount(tester);
      }
    },
  );

  testWidgets('failed initialization shows unavailable and disables analysis', (
    tester,
  ) async {
    final source = await tester.runAsync(
      () => fixture.file('original.mp4', 'original'),
    );
    fixture.state.project = fixture.project(source!.path);
    platform.failInitialize = true;
    await mount(tester);
    try {
      await tester.pump();
      expect(fixture.state.videoSourceFailure, VideoSourceFailure.unplayable);
      expect(find.text('视频不可用'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('start-analysis')))
            .onPressed,
        isNull,
      );
      expect(platform.disposed, isNotEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await unmount(tester);
    }
  });

  testWidgets('playback error after initialization also disables analysis', (
    tester,
  ) async {
    final source = await tester.runAsync(
      () => fixture.file('original.mp4', 'original'),
    );
    fixture.state.project = fixture.project(source!.path);
    await mount(tester);
    try {
      tester.widget<VideoPlayer>(find.byType(VideoPlayer)).controller.value =
          VideoPlayerValue.erroneous('injected runtime failure');
      await tester.pump();
      await tester.pump();
      expect(fixture.state.videoSourceFailure, VideoSourceFailure.unplayable);
      expect(find.text('视频不可用'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('start-analysis')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await unmount(tester);
    }
  });

  testWidgets(
    'analysis-range preview observes a same-path source replacement',
    (tester) async {
      final path = await tester.runAsync(
        () async => (await fixture.file(
          'BHE Mobile/videos/A/source.mp4',
          'original',
        )).resolveSymbolicLinks(),
      );
      fixture.state.project = fixture.project(path!);
      await mount(tester);
      try {
        final range = find.text('分析范围');
        await tester.ensureVisible(range);
        await tester.pump();
        await tester.tap(range);
        await tester.pump();
        await tester.runAsync(() => pumpEventQueue());
        await tester.pumpAndSettle();
        final preview = find.byKey(const ValueKey('analysis-range-preview'));
        final video = find.descendant(
          of: preview,
          matching: find.byType(VideoPlayer),
        );
        final old = tester.widget<VideoPlayer>(video).controller;
        await tester.runAsync(() async {
          fixture.choose(await fixture.file('replacement.mp4', 'original'));
          await fixture.state.relinkVideo();
        });
        expect(fixture.state.project.video!.path, path);
        await tester.pump();
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump();
        final next = tester.widget<VideoPlayer>(video).controller;
        expect(next.playerId, isNot(old.playerId));
        expect(next.value.isInitialized, isTrue);
        expect(platform.disposed, contains(old.playerId));
        expect(tester.takeException(), isNull);
      } finally {
        await unmount(tester);
      }
    },
  );
  for (final error in ['initialize', 'seek']) {
    testWidgets(
      'clip range $error failure is static and reopening the same path starts a new player',
      (tester) async {
        final file = await tester.runAsync(
          () => fixture.file('original.mp4', 'original'),
        );
        Widget editor() => MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: BheLocalizations.localizationsDelegates,
          supportedLocales: BheLocalizations.supportedLocales,
          home: Scaffold(
            body: ClipRangeEditor(
              videoPath: file!.path,
              aspectRatio: 16 / 9,
              durationMs: 10000,
              startMs: 1000,
              endMs: 3000,
              title: 'Range',
              confirmLabel: 'Apply',
            ),
          ),
        );
        platform.failInitialize = error == 'initialize';
        platform.failSeek = error == 'seek';
        await tester.pumpWidget(editor());
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump();
        try {
          expect(find.text('Video unavailable'), findsOneWidget);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          expect(platform.disposed, contains(0));
          await unmount(tester);
          platform.failInitialize = false;
          platform.failSeek = false;
          await tester.pumpWidget(editor());
          await tester.runAsync(() => pumpEventQueue());
          await tester.pump();
          final player = tester
              .widget<VideoPlayer>(find.byType(VideoPlayer))
              .controller;
          expect(player.playerId, isNot(0));
          expect(player.value.isInitialized, isTrue);
          expect(tester.takeException(), isNull);
        } finally {
          await unmount(tester);
        }
      },
    );
  }
  testWidgets(
    'a preview seek failure is caught and exposes recovery without an unhandled future',
    (tester) async {
      final source = await tester.runAsync(
        () => fixture.file('original.mp4', 'original'),
      );
      fixture.state.project = fixture.project(source!.path);
      await mount(tester);
      try {
        platform.failSeek = true;
        final slider = find.descendant(
          of: find.byKey(const ValueKey('project-video-preview')),
          matching: find.byType(Slider),
        );
        tester.widget<Slider>(slider).onChanged!(2500);
        await tester.pump();
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump();
        await tester.pump();
        expect(fixture.state.videoSourceFailure, VideoSourceFailure.unplayable);
        expect(find.text('视频不可用'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await unmount(tester);
      }
    },
  );

  testWidgets(
    'a running clip player failure offers feedback with the original error',
    (tester) async {
      DiagnosticErrorRecord? captured;
      final source = await tester.runAsync(
        () => fixture.file('clip.mp4', 'original'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ClipRangeEditor(
              videoPath: source!.path,
              aspectRatio: 16 / 9,
              durationMs: 10000,
              startMs: 1000,
              endMs: 5000,
              title: 'Clip',
              confirmLabel: 'Done',
              onFeedback: (error) => captured = error,
            ),
          ),
        ),
      );
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      final player = tester
          .widget<VideoPlayer>(find.byType(VideoPlayer))
          .controller;
      player.value = VideoPlayerValue.erroneous(
        'injected runtime codec failure',
      );
      await tester.pump();
      expect(find.byType(VideoPlayer), findsNothing);
      final feedback = find.text('反馈');
      await tester.ensureVisible(feedback);
      await tester.tap(feedback);
      await tester.pump();
      expect(
        captured?.error.toString(),
        contains('injected runtime codec failure'),
      );
      expect(tester.takeException(), isNull);
      await unmount(tester);
    },
  );
}
