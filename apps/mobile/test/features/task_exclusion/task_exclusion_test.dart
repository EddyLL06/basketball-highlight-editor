import 'dart:async';

import 'package:bhe_mobile/features/export/export_modes.dart';
import 'package:bhe_mobile/media_bridge.dart';
import 'package:bhe_mobile/native_analysis_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const analysis = MethodChannel('com.bhe.bhe/mobile_analysis');
  const events = MethodChannel('com.bhe.bhe/mobile_analysis_progress');
  const media = MethodChannel('com.bhe.bhe/mobile_media');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late MobileVideoFixture f;
  setUp(() => messenger.setMockMethodCallHandler(events, (_) async => null));
  tearDown(() async {
    messenger.setMockMethodCallHandler(analysis, null);
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMockMethodCallHandler(media, null);
    await f.close();
  });

  for (final nativeStarted in [false, true]) {
    test(
      'analysis ${nativeStarted ? 'native execution' : 'model preparation'} excludes exports and permits retry after cancellation',
      () async {
        final preparation = Completer<String>();
        final prepared = Completer<void>();
        final started = Completer<void>();
        final nativeResult = Completer<Object?>();
        var exports = 0;
        f = MobileVideoFixture();
        await f.init(
          engine: NativeAnalysisEngine(
            modelPreparer: () {
              prepared.complete();
              return preparation.future;
            },
          ),
        );
        final file = await f.file('original.mp4', 'original');
        f.state.project = f.project(file.path);
        messenger.setMockMethodCallHandler(analysis, (call) async {
          if (call.method == 'analyzeVideo') {
            started.complete();
            return nativeResult.future;
          }
          if (call.method == 'isAnalysisActive') return false;
          return null;
        });
        messenger.setMockMethodCallHandler(media, (call) async {
          if (call.method == 'registerMergeExport') return true;
          if (call.method == 'mergeClips') {
            exports++;
            return {'outputPath': 'out.mp4', 'committed': true};
          }
          if (call.method == 'exportClip') exports++;
          return null;
        });
        final running = f.state.startAnalysis();
        await prepared.future;
        if (nativeStarted) {
          preparation.complete('/model');
          await started.future;
        }
        expect(f.state.analysing, isTrue);
        final beforeProgress = f.state.progress;
        final beforeMessage = f.state.progressMessage;
        final beforeError = f.state.errorMessage;
        await f.state.mergeClips();
        await f.state.mergeClipsInScope(const ExportScope.only({'Alice'}));
        await f.state.exportClips();
        await f.state.exportClipsInScope(const ExportScope.only({'Alice'}));
        expect(exports, 0);
        expect(f.state.exportStartBlockReason, '正在分析，请等待分析结束。');
        expect(f.state.progress, beforeProgress);
        expect(f.state.progressMessage, beforeMessage);
        expect(f.state.errorMessage, beforeError);
        expect(f.state.analysing, isTrue);
        await f.state.cancelAnalysis();
        if (!preparation.isCompleted) preparation.complete('/model');
        if (nativeStarted) nativeResult.complete({'candidates': <Object>[]});
        await running;
        await pumpEventQueue();
        expect(f.state.project.candidates.single.id, 'goal');
        await f.state.mergeClips();
        expect(exports, 1);
      },
    );
  }

  for (final merge in [true, false]) {
    test(
      '${merge ? 'merged' : 'separate'} export excludes analysis and allows it after cancellation',
      () async {
        final started = Completer<void>();
        final result = Completer<Object?>();
        var analyses = 0;
        f = MobileVideoFixture();
        await f.init(
          engine: NativeAnalysisEngine(
            modelPreparer: () async {
              analyses++;
              return '/model';
            },
          ),
        );
        final file = await f.file('original.mp4', 'original');
        f.state.project = f.project(file.path);
        messenger.setMockMethodCallHandler(analysis, (call) async {
          if (call.method == 'analyzeVideo') return {'candidates': <Object>[]};
          return null;
        });
        messenger.setMockMethodCallHandler(media, (call) async {
          if (call.method == 'registerMergeExport') return true;
          if (call.method == (merge ? 'mergeClips' : 'exportClip')) {
            started.complete();
            return result.future;
          }
          return null;
        });
        final running = merge ? f.state.mergeClips() : f.state.exportClips();
        await started.future;
        final beforeProgress = f.state.progress;
        final beforeMessage = f.state.progressMessage;
        final beforeError = f.state.errorMessage;
        await f.state.startAnalysis();
        expect(analyses, 0);
        expect(f.state.analysisStartBlockReason, '正在导出，请等待导出结束。');
        expect(f.state.canStartAnalysis, isFalse);
        expect(f.state.exporting, isTrue);
        expect(f.state.progress, beforeProgress);
        expect(f.state.progressMessage, beforeMessage);
        expect(f.state.errorMessage, beforeError);
        await f.state.cancelExport();
        result.completeError(PlatformException(code: 'EXPORT_CANCELLED'));
        await running;
        await pumpEventQueue();
        expect(f.state.analysisStartBlockReason, isNull);
        await f.state.startAnalysis();
        expect(analyses, 1);
      },
    );
  }

  test(
    'uncertain export blocks analysis across project switch until native returns',
    () async {
      final entered = Completer<void>(), result = Completer<Object?>();
      var analyses = 0, notices = 0;
      f = MobileVideoFixture();
      await f.init(
        engine: NativeAnalysisEngine(
          modelPreparer: () async {
            analyses++;
            return '/model';
          },
        ),
        exportEngine: NativeMediaExportEngine(
          drainTimeout: const Duration(milliseconds: 40),
        ),
        exportDrainTimeout: const Duration(milliseconds: 40),
      );
      final file = await f.file('original.mp4', 'original');
      f.state.project = f.project(file.path);
      messenger.setMockMethodCallHandler(
        analysis,
        (call) async =>
            call.method == 'analyzeVideo' ? {'candidates': <Object>[]} : null,
      );
      messenger.setMockMethodCallHandler(media, (call) async {
        if (call.method == 'registerMergeExport') return true;
        if (call.method == 'mergeClips') {
          entered.complete();
          return result.future;
        }
        if (call.method == 'isExportActive') return true;
        return null;
      });
      final running = f.state.mergeClips();
      await entered.future;
      await f.state.createNewProject();
      f.state.project = f.project(file.path, id: 'B');
      f.state.addListener(() => notices++);
      expect(f.state.hasUncertainExport, isFalse);
      expect(f.state.canStartAnalysis, isFalse);
      await f.state.startAnalysis();
      expect(analyses, 0);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(f.state.hasUncertainExport, isTrue);
      expect(f.state.analysisStartBlockReason, '上次任务尚未确认结束，请先确认停止。');
      await f.state.startAnalysis();
      expect(analyses, 0);
      final oldNotices = notices;
      result.completeError(PlatformException(code: 'EXPORT_CANCELLED'));
      await running;
      await pumpEventQueue();
      expect(f.state.hasUncertainExport, isFalse);
      expect(notices, greaterThan(oldNotices));
      expect(f.state.canStartAnalysis, isTrue);
      await f.state.startAnalysis();
      expect(analyses, 1);
    },
  );

  test('uncertain analysis blocks both exports until native exit', () async {
    final entered = Completer<void>(), result = Completer<Object?>();
    var active = true, exports = 0;
    f = MobileVideoFixture();
    await f.init(
      engine: NativeAnalysisEngine(modelPreparer: () async => '/model'),
      analysisStartupTimeout: const Duration(milliseconds: 40),
    );
    final file = await f.file('original.mp4', 'original');
    f.state.project = f.project(file.path);
    await f.state.updateCandidateNote('goal', 'keep');
    messenger.setMockMethodCallHandler(analysis, (call) async {
      if (call.method == 'analyzeVideo') {
        entered.complete();
        return result.future;
      }
      if (call.method == 'isAnalysisActive') return active;
      return null;
    });
    messenger.setMockMethodCallHandler(media, (call) async {
      if (call.method == 'registerMergeExport') return true;
      if (call.method == 'mergeClips') {
        exports++;
        return {'outputPath': 'out.mp4', 'committed': true};
      }
      if (call.method == 'exportClip') exports++;
      return null;
    });
    final running = f.state.startAnalysis();
    await entered.future;
    await running;
    expect(f.state.hasUncertainAnalysis, isTrue);
    final error = f.state.errorMessage;
    final progress = f.state.progressMessage;
    await f.state.mergeClips();
    await f.state.exportClips();
    expect(exports, 0);
    expect(f.state.exportStartBlockReason, '上次任务尚未确认结束，请先确认停止。');
    expect(f.state.errorMessage, error);
    expect(f.state.progressMessage, progress);
    expect(f.state.project.candidates.single.note, 'keep');
    expect(f.state.canUndoReview, isTrue);
    active = false;
    result.complete({'candidates': <Object>[]});
    await pumpEventQueue();
    await f.state.checkUncertainAnalysis();
    expect(f.state.hasUncertainAnalysis, isFalse);
    await f.state.mergeClips();
    expect(exports, 1);
  });
  test(
    'project switch during committed export cleanup refreshes analysis admission',
    () async {
      final releaseEntered = Completer<void>(), release = Completer<void>();
      f = MobileVideoFixture();
      await f.init(exportDrainTimeout: const Duration(seconds: 2));
      final file = await f.file('original.mp4', 'original');
      f.state.project = f.project(file.path);
      messenger.setMockMethodCallHandler(media, (call) async {
        if (call.method == 'registerMergeExport') return true;
        if (call.method == 'mergeClips') {
          return {'outputPath': 'out.mp4', 'committed': true};
        }
        if (call.method == 'releaseMergeExport') {
          releaseEntered.complete();
          await release.future;
        }
        return null;
      });
      final running = f.state.mergeClips();
      await releaseEntered.future;
      expect(f.state.exportedPaths, ['out.mp4']);
      await f.state.createNewProject();
      f.state.project = f.project(file.path, id: 'B');
      expect(f.state.canStartAnalysis, isFalse);
      var notices = 0;
      f.state.addListener(() => notices++);
      release.complete();
      await running;
      await pumpEventQueue();
      expect(f.state.canStartAnalysis, isTrue);
      expect(notices, greaterThan(0));
    },
  );
  test(
    'cancel acknowledgement does not admit export while the native analysis worker remains active',
    () async {
      final entered = Completer<void>(), result = Completer<Object?>();
      var active = true, exports = 0;
      f = MobileVideoFixture();
      await f.init(
        engine: NativeAnalysisEngine(modelPreparer: () async => '/model'),
      );
      final file = await f.file('original.mp4', 'original');
      f.state.project = f.project(file.path);
      messenger.setMockMethodCallHandler(analysis, (call) async {
        if (call.method == 'analyzeVideo') {
          entered.complete();
          return result.future;
        }
        if (call.method == 'isAnalysisActive') return active;
        return null;
      });
      messenger.setMockMethodCallHandler(media, (call) async {
        if (call.method == 'registerMergeExport') return true;
        if (call.method == 'mergeClips') {
          exports++;
          return {'outputPath': 'out.mp4', 'committed': true};
        }
        return null;
      });
      final running = f.state.startAnalysis();
      await entered.future;
      await f.state.cancelAnalysis();
      await running;
      expect(f.state.analysing, isFalse);
      expect(f.state.hasUncertainAnalysis, isTrue);
      await f.state.mergeClips();
      expect(exports, 0);
      expect(f.state.project.candidates.single.id, 'goal');
      active = false;
      result.complete({'candidates': <Object>[]});
      await pumpEventQueue();
      await f.state.checkUncertainAnalysis();
      expect(f.state.hasUncertainAnalysis, isFalse);
      await f.state.mergeClips();
      expect(exports, 1);
    },
  );
  test(
    'cancel after native progress keeps export blocked until worker exit',
    () async {
      final entered = Completer<void>(), result = Completer<Object?>();
      var active = true, exports = 0;
      f = MobileVideoFixture();
      await f.init(
        engine: NativeAnalysisEngine(modelPreparer: () async => '/model'),
      );
      final file = await f.file('original.mp4', 'original');
      f.state.project = f.project(file.path);
      messenger.setMockMethodCallHandler(analysis, (call) async {
        if (call.method == 'analyzeVideo') {
          entered.complete();
          return result.future;
        }
        if (call.method == 'isAnalysisActive') return active;
        return null;
      });
      messenger.setMockMethodCallHandler(media, (call) async {
        if (call.method == 'mergeClips' || call.method == 'exportClip') {
          exports++;
        }
        return null;
      });
      final running = f.state.startAnalysis();
      await entered.future;
      final event = const StandardMethodCodec().encodeSuccessEnvelope({
        'stage': 'refineCandidates',
        'progress': 0.4,
        'message': 'native progress',
      });
      await messenger.handlePlatformMessage(events.name, event, (_) {});
      for (
        var i = 0;
        i < 100 && f.state.project.lastAnalysisStatus != 'running';
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(f.state.project.lastAnalysisStatus, 'running');
      await f.state.mergeClips();
      expect(exports, 0);
      await f.state.cancelAnalysis();
      expect(f.state.hasUncertainAnalysis, isTrue);
      await f.state.exportClips();
      expect(exports, 0);
      active = false;
      result.complete({'candidates': <Object>[]});
      await running;
      await pumpEventQueue();
      await f.state.checkUncertainAnalysis();
      expect(f.state.exportStartBlockReason, isNull);
    },
  );
}
