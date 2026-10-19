import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:desktop/components/cs_button.dart';
import 'package:desktop/features/export/export_screen.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:desktop/providers/playback_coordinator.dart';
import 'package:desktop/providers/export_output_picker.dart';
import 'package:desktop/theme/app_theme.dart';

void main() {
  testWidgets(
    'export waits for paused previews and prevents duplicate native dialogs',
    (tester) async {
      final coordinator = PlaybackCoordinator();
      final paused = Completer<void>();
      coordinator.register(Object(), () => paused.future);
      final picker = _TestOutputPicker();
      final notifier = _TrackingExportNotifier();
      await _pumpExport(tester, coordinator, picker, notifier);
      final merge = find.widgetWithText(CsButton, '合并导出');
      await tester.ensureVisible(merge);
      await tester.tap(merge);
      await tester.pump();
      expect(picker.calls, 0);
      expect(tester.widget<CsButton>(merge).onPressed, isNull);
      expect(find.text('正在准备输出位置…'), findsOneWidget);
      paused.complete();
      await tester.pump();
      await tester.pump();
      expect(picker.calls, 1);
      picker.result.complete(null);
      await tester.pumpAndSettle();
      expect(notifier.exports, isEmpty);
      expect(tester.widget<CsButton>(merge).onPressed, isNotNull);
      picker.result = Completer<String?>();
      await tester.tap(merge);
      await tester.pump();
      await tester.pump();
      expect(picker.calls, 2);
      picker.result.complete('/tmp/highlights.mp4');
      await tester.pumpAndSettle();
      expect(notifier.exports, ['merge:/tmp/highlights.mp4']);
    },
  );

  testWidgets(
    'failed pause never opens native dialog and leaves export retryable',
    (tester) async {
      final coordinator = PlaybackCoordinator();
      coordinator.register(Object(), () async {
        throw StateError('pause failed');
      });
      final picker = _TestOutputPicker();
      final notifier = _TrackingExportNotifier();
      await _pumpExport(tester, coordinator, picker, notifier);
      final merge = find.widgetWithText(CsButton, '合并导出');
      await tester.ensureVisible(merge);
      await tester.tap(merge);
      await tester.pump();
      await tester.pump();
      expect(picker.calls, 0);
      expect(notifier.exports, isEmpty);
      expect(find.textContaining('选择输出位置失败'), findsOneWidget);
      expect(tester.widget<CsButton>(merge).onPressed, isNotNull);
    },
  );

  testWidgets('separate export uses the same paused native-dialog path', (
    tester,
  ) async {
    final picker = _TestOutputPicker();
    final notifier = _TrackingExportNotifier();
    await _pumpExport(tester, PlaybackCoordinator(), picker, notifier);
    final separate = find.widgetWithText(CsButton, '分别导出');
    await tester.ensureVisible(separate);
    await tester.tap(separate);
    await tester.pump();
    await tester.pump();
    picker.result.complete('/tmp/clips');
    await tester.pumpAndSettle();
    expect(notifier.exports, ['separate:/tmp/clips']);
  });

  testWidgets('导出历史提供打开目录按钮', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectProvider.overrideWith(
            () => _ExportNotifier(
              const ProjectState(
                exportHistory: [
                  {
                    'mode': 'merge',
                    'candidate_count': 2,
                    'duration_ms': 12000,
                    'processing_ms': 3000,
                    'output_path': '/tmp/highlights.mp4',
                    'metadata': {
                      'files': ['/tmp/highlights.mp4'],
                    },
                    'created_at': '2026-08-07T01:00:00.000Z',
                  },
                ],
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: appTheme(Brightness.dark),
          home: const Scaffold(body: ExportScreen()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('打开目录'), findsOneWidget);
  });

  testWidgets('快速分析导出前显示漏检风险但不阻塞导出', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          projectProvider.overrideWith(
            () => _ExportNotifier(
              const ProjectState(
                analysisMode: 'fast',
                candidates: [
                  {
                    'id': 'candidate-1',
                    'event_time_ms': 12000,
                    'default_start_ms': 6000,
                    'default_end_ms': 15000,
                  },
                ],
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: appTheme(Brightness.dark),
          home: const Scaffold(body: ExportScreen()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('当前结果来自快速分析，可能漏检；如需更完整结果，建议先用标准模式重新分析。'), findsOneWidget);
    expect(
      tester.widget<CsButton>(find.widgetWithText(CsButton, '合并导出')).onPressed,
      isNotNull,
    );
    expect(
      tester.widget<CsButton>(find.widgetWithText(CsButton, '分别导出')).onPressed,
      isNotNull,
    );
  });
}

class _ExportNotifier extends ProjectNotifier {
  _ExportNotifier(this.initialState);

  final ProjectState initialState;

  @override
  ProjectState build() => initialState;
}

Future<void> _pumpExport(
  WidgetTester tester,
  PlaybackCoordinator coordinator,
  _TestOutputPicker picker,
  _TrackingExportNotifier notifier,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        projectProvider.overrideWith(() => notifier),
        playbackCoordinatorProvider.overrideWithValue(coordinator),
        exportOutputPickerProvider.overrideWithValue(picker),
      ],
      child: const MaterialApp(home: Scaffold(body: ExportScreen())),
    ),
  );
  await tester.pumpAndSettle();
}

class _TestOutputPicker extends ExportOutputPicker {
  var result = Completer<String?>();
  var calls = 0;
  @override
  Future<String?> mergedPath({required String typeLabel}) {
    calls++;
    return result.future;
  }

  @override
  Future<String?> directory({required String confirmLabel}) {
    calls++;
    return result.future;
  }
}

class _TrackingExportNotifier extends _ExportNotifier {
  _TrackingExportNotifier()
    : super(
        const ProjectState(
          candidates: [
            {'id': 'c1', 'default_start_ms': 0, 'default_end_ms': 4000},
          ],
        ),
      );
  final exports = <String>[];
  @override
  Future<void> export(
    String mode, {
    String? outputDir,
    String? outputPath,
    List<String>? playerIds,
    bool? includeUnassigned,
  }) async {
    exports.add('$mode:${outputPath ?? outputDir}');
  }
}
