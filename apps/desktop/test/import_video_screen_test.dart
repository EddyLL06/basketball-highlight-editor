import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:desktop/providers/pending_import_provider.dart';
import 'package:desktop/providers/project_state.dart';

import 'package:desktop/features/import_video/import_video_screen.dart';

void main() {
  for (final frame in [
    const Size(1440, 1080),
    const Size(1920, 1080),
    const Size(1080, 1920),
  ]) {
    testWidgets('analysis range preview fills the frame for $frame', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1100, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            projectProvider.overrideWith(() => _RangeNotifier(frame)),
          ],
          child: const MaterialApp(home: Scaffold(body: ImportVideoScreen())),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final preview = find.byKey(const Key('analysis-range-video-frame'));
      expect(preview, findsOneWidget);
      final size = tester.getSize(preview);
      // Cover mode: fixed-height, full-width frame regardless of the source
      // aspect ratio — no letterbox bars for 4:3 sources.
      expect(size.height, 440);
      expect(size.width, greaterThan(frame.aspectRatio > 1 ? 500 : 200));
      expect(
        tester.getRect(find.byKey(const Key('import-footer'))).bottom,
        lessThanOrEqualTo(700),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('imports a video dropped on the home screen', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final notifier = _DropNotifier();
    final container = ProviderContainer(
      overrides: [projectProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);
    container.read(pendingImportProvider.notifier).set('/v/game.MP4');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ImportVideoScreen())),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(notifier.selectedPaths, ['/v/game.MP4']);
    expect(container.read(pendingImportProvider), isNull);
  });

  test(
    'estimates standard analysis from the selected range and resolution',
    () {
      final estimate = estimateAnalysisDuration(
        startMs: 0,
        endMs: const Duration(minutes: 30).inMilliseconds,
        width: 1920,
        height: 1080,
        mode: 'standard',
      );

      expect(estimate.label, '约 4–9 分钟');
    },
  );

  test('estimates fast analysis shorter than standard analysis', () {
    const args = <String, int>{
      'startMs': 0,
      'endMs': 1800000,
      'width': 1920,
      'height': 1080,
    };
    final standard = estimateAnalysisDuration(
      startMs: args['startMs']!,
      endMs: args['endMs']!,
      width: args['width']!,
      height: args['height']!,
      mode: 'standard',
    );
    final fast = estimateAnalysisDuration(
      startMs: args['startMs']!,
      endMs: args['endMs']!,
      width: args['width']!,
      height: args['height']!,
      mode: 'fast',
    );

    expect(fast.minimum.inSeconds, lessThan(standard.minimum.inSeconds));
    expect(fast.maximum.inSeconds, lessThan(standard.maximum.inSeconds));
  });

  test('collapses a short estimate with identical rounded bounds', () {
    final estimate = estimateAnalysisDuration(
      startMs: 0,
      endMs: 277000,
      width: 1440,
      height: 1080,
      mode: 'fast',
    );

    expect(estimate.label, '约 1 分钟');
  });
}

class _RangeNotifier extends ProjectNotifier {
  _RangeNotifier(this.frame);
  final Size frame;

  @override
  ProjectState build() => ProjectState(
    video: {
      'id': 'v1',
      'duration_ms': 60000,
      'width': frame.width,
      'height': frame.height,
    },
    workflowDraft: const {'step': 1},
  );
}

class _DropNotifier extends ProjectNotifier {
  final selectedPaths = <String>[];

  @override
  ProjectState build() => const ProjectState();

  @override
  Future<Map<String, dynamic>?> loadWorkflowDraft() async => null;

  @override
  Future<void> selectVideo(String path) async => selectedPaths.add(path);
}
