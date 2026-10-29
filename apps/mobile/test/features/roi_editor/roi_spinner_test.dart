import 'dart:async';

import 'package:bhe_mobile/mobile_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import '../../support/fake_video_platform.dart';
import '../../support/mobile_video_fixture.dart';

class _DelayedSeekPlatform extends FakeVideoPlatform {
  Completer<void>? gate;
  Completer<void>? entered;

  void delayNextSeek() {
    gate = Completer<void>();
    entered = Completer<void>();
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    final pending = gate;
    if (pending != null && !pending.isCompleted) {
      if (!entered!.isCompleted) entered!.complete();
      await pending.future;
    }
    await super.seekTo(playerId, position);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MobileVideoFixture fixture;
  late VideoPlayerPlatform previous;
  late _DelayedSeekPlatform platform;
  setUp(() async {
    fixture = MobileVideoFixture();
    await fixture.init();
    previous = VideoPlayerPlatform.instance;
    platform = _DelayedSeekPlatform();
    VideoPlayerPlatform.instance = platform;
  });
  tearDown(() async {
    if (platform.gate case final gate? when !gate.isCompleted) gate.complete();
    await fixture.close();
    VideoPlayerPlatform.instance = previous;
  });

  Finder sheet() => find.byWidgetPredicate(
    (widget) => widget.runtimeType.toString() == '_RoiEditorSheet',
  );
  Finder inside(Type type) =>
      find.descendant(of: sheet(), matching: find.byType(type));

  Future<void> mount(WidgetTester tester, int startMs, Size size) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale('zh');
    await tester.binding.setSurfaceSize(size);
    final source = await tester.runAsync(
      () => fixture.file('original.mp4', 'original'),
    );
    final project = fixture.project(source!.path);
    fixture.state.project = project.copyWith(
      settings: project.settings.copyWith(startMs: startMs),
    );
    await tester.pumpWidget(BheMobileApp(appState: fixture.state));
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
  }

  Future<void> open(WidgetTester tester) async {
    final setting = find.text('投篮分析区与篮网区');
    await tester.ensureVisible(setting);
    await tester.pump();
    await tester.tap(setting);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
  }

  Future<void> release(WidgetTester tester) async {
    await tester.runAsync(() async {
      platform.gate!.complete();
      await pumpEventQueue();
    });
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => pumpEventQueue());
    await tester.binding.setSurfaceSize(null);
    tester.binding.platformDispatcher.clearLocaleTestValue();
  }

  for (final start in [0, 1200]) {
    for (final size in [const Size(360, 800), const Size(800, 360)]) {
      testWidgets('ready without interaction start=$start size=$size', (
        tester,
      ) async {
        await mount(tester, start, size);
        try {
          platform.delayNextSeek();
          await open(tester);
          expect(platform.entered!.isCompleted, isTrue);
          expect(inside(CircularProgressIndicator), findsOneWidget);
          await release(tester);
          expect(inside(VideoPlayer), findsOneWidget);
          expect(inside(CircularProgressIndicator), findsNothing);
          expect(
            tester
                .widget<VideoPlayer>(inside(VideoPlayer))
                .controller
                .value
                .isInitialized,
            isTrue,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await unmount(tester);
        }
      });
    }
  }

  testWidgets('player state changes rebuild even at the same position', (
    tester,
  ) async {
    await mount(tester, 1200, const Size(360, 800));
    try {
      platform.delayNextSeek();
      await open(tester);
      await release(tester);
      final player = tester.widget<VideoPlayer>(inside(VideoPlayer)).controller;
      player.value = player.value.copyWith(isPlaying: true);
      await tester.pump();
      expect(
        find.descendant(of: sheet(), matching: find.byIcon(LucideIcons.pause)),
        findsOneWidget,
      );
      player.value = player.value.copyWith(isPlaying: false);
      await tester.pump();
      expect(
        find.descendant(of: sheet(), matching: find.byIcon(LucideIcons.play)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await unmount(tester);
    }
  });

  testWidgets('open failure shows recovery instead of a spinner', (
    tester,
  ) async {
    await mount(tester, 0, const Size(360, 800));
    try {
      platform.failInitialize = true;
      await open(tester);
      expect(find.byType(RoiPreviewFailure), findsOneWidget);
      expect(inside(CircularProgressIndicator), findsNothing);
      expect(inside(VideoPlayer), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await unmount(tester);
    }
  });

  testWidgets('close while opening then reopen discards old player', (
    tester,
  ) async {
    await mount(tester, 0, const Size(360, 800));
    try {
      platform.delayNextSeek();
      await open(tester);
      final oldGate = platform.gate!;
      final oldId = platform.sources.keys.last;
      expect(platform.entered!.isCompleted, isTrue);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(sheet(), findsNothing);
      platform.delayNextSeek();
      await open(tester);
      final newId = platform.sources.keys.last;
      expect(newId, isNot(oldId));
      await tester.runAsync(() async {
        oldGate.complete();
        await pumpEventQueue();
      });
      await tester.pump();
      expect(platform.disposed, contains(oldId));
      expect(inside(CircularProgressIndicator), findsOneWidget);
      await release(tester);
      expect(
        tester.widget<VideoPlayer>(inside(VideoPlayer)).controller.playerId,
        newId,
      );
      expect(inside(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await unmount(tester);
    }
  });
  testWidgets('readiness changes rebuild without a position change', (
    tester,
  ) async {
    await mount(tester, 0, const Size(360, 800));
    try {
      platform.delayNextSeek();
      await open(tester);
      await release(tester);
      final player = tester.widget<VideoPlayer>(inside(VideoPlayer)).controller;
      final ready = player.value;
      player.value = ready.copyWith(isInitialized: false);
      await tester.pump();
      expect(inside(CircularProgressIndicator), findsOneWidget);
      expect(inside(VideoPlayer), findsNothing);
      player.value = ready;
      await tester.pump();
      expect(inside(VideoPlayer), findsOneWidget);
      expect(inside(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await unmount(tester);
    }
  });

  testWidgets('runtime player failure shows recovery and diagnostics', (
    tester,
  ) async {
    await mount(tester, 0, const Size(360, 800));
    try {
      platform.delayNextSeek();
      await open(tester);
      await release(tester);
      final player = tester.widget<VideoPlayer>(inside(VideoPlayer)).controller;
      final playerId = player.playerId;
      player.value = VideoPlayerValue.erroneous('injected runtime failure');
      await tester.pump();
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      expect(find.byType(RoiPreviewFailure), findsOneWidget);
      expect(inside(CircularProgressIndicator), findsNothing);
      expect(inside(VideoPlayer), findsNothing);
      expect(
        tester
            .widget<RoiPreviewFailure>(find.byType(RoiPreviewFailure))
            .diagnostic
            ?.error
            .toString(),
        contains('injected runtime failure'),
      );
      expect(platform.disposed, contains(playerId));
      expect(tester.takeException(), isNull);
    } finally {
      await unmount(tester);
    }
  });

  testWidgets('orientation rebuild keeps the ready player', (tester) async {
    await mount(tester, 0, const Size(360, 800));
    try {
      platform.delayNextSeek();
      await open(tester);
      await release(tester);
      final player = tester.widget<VideoPlayer>(inside(VideoPlayer)).controller;
      await tester.binding.setSurfaceSize(const Size(800, 360));
      await tester.pump();
      expect(
        tester.widget<VideoPlayer>(inside(VideoPlayer)).controller,
        same(player),
      );
      expect(inside(CircularProgressIndicator), findsNothing);
      await tester.binding.setSurfaceSize(const Size(360, 800));
      await tester.pump();
      expect(
        tester.widget<VideoPlayer>(inside(VideoPlayer)).controller,
        same(player),
      );
      expect(tester.takeException(), isNull);
    } finally {
      await unmount(tester);
    }
  });
  testWidgets(
    'small position changes are throttled while larger changes update time',
    (tester) async {
      await mount(tester, 980, const Size(360, 800));
      try {
        platform.delayNextSeek();
        await open(tester);
        await release(tester);
        final player = tester
            .widget<VideoPlayer>(inside(VideoPlayer))
            .controller;
        expect(
          find.descendant(of: sheet(), matching: find.text('0:00 / 0:10')),
          findsOneWidget,
        );
        player.value = player.value.copyWith(
          position: const Duration(milliseconds: 1000),
        );
        await tester.pump();
        expect(
          find.descendant(of: sheet(), matching: find.text('0:00 / 0:10')),
          findsOneWidget,
        );
        player.value = player.value.copyWith(
          position: const Duration(milliseconds: 1080),
        );
        await tester.pump();
        expect(
          find.descendant(of: sheet(), matching: find.text('0:01 / 0:10')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await unmount(tester);
      }
    },
  );
}
