import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/features/import_video/import_video_screen.dart';
import 'package:desktop/providers/project_state.dart';

class _RangeNotifier extends ProjectNotifier {
  _RangeNotifier(this.startMs);

  final int startMs;

  @override
  ProjectState build() => ProjectState(
    video: {
      'id': 'v1',
      'duration_ms': 60000,
      'width': 1920,
      'height': 1080,
      'analysis_start_ms': startMs,
      'analysis_end_ms': 10000,
    },
    previewTimeMs: 20000,
  );

  @override
  Future<Map<String, dynamic>?> loadWorkflowDraft() async => null;

  @override
  Future<void> saveWorkflowDraft(Map<String, dynamic> draft) async {}
}

void main() {
  // 标记画面停在分析范围之外时，进入检测区域要回到范围起点（包括起点为 0）。
  for (final startMs in [2000, 0]) {
    testWidgets('超出分析范围的标记画面回到起点 $startMs', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [projectProvider.overrideWith(() => _RangeNotifier(startMs))],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: Scaffold(body: ImportVideoScreen())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('下一步').last);
      await tester.pumpAndSettle();

      expect(container.read(projectProvider).previewTimeMs, startMs);
    });
  }
}
