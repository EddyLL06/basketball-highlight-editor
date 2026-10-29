import 'dart:async';

import 'package:bhe_mobile/features/operation_status/task_stop_status.dart';
import 'package:bhe_mobile/native_analysis_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const analysisChannel = MethodChannel('com.bhe.bhe/mobile_analysis');
  const progressChannel = MethodChannel('com.bhe.bhe/mobile_analysis_progress');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test(
    'cancel failure survives repeated marking, startup timeout and late result',
    () async {
      final f = MobileVideoFixture();
      final entered = Completer<void>(), result = Completer<Object?>();
      var cancels = 0, checks = 0, active = true, failCheck = true;
      messenger.setMockMethodCallHandler(progressChannel, (_) async => null);
      await f.init(
        engine: NativeAnalysisEngine(modelPreparer: () async => '/model'),
        analysisStartupTimeout: const Duration(milliseconds: 300),
        analysisCancelTimeout: const Duration(milliseconds: 100),
      );
      try {
        final file = await f.file('original.mp4', 'original');
        f.state.project = f.project(file.path);
        await f.state.updateCandidateNote('goal', 'keep');
        messenger.setMockMethodCallHandler(analysisChannel, (call) async {
          if (call.method == 'analyzeVideo') {
            entered.complete();
            return result.future;
          }
          if (call.method == 'cancelAnalysis') {
            cancels++;
            if (cancels == 3) {
              throw PlatformException(code: 'ANALYSIS_CANCELLED');
            }
            throw PlatformException(
              code: 'CANCEL_FAIL',
              message: 'failure $cancels',
            );
          }
          if (call.method == 'isAnalysisActive') {
            checks++;
            if (failCheck) throw PlatformException(code: 'STATUS_FAIL');
            return active;
          }
          return null;
        });
        final analysis = f.state.startAnalysis();
        await entered.future;
        await f.state.cancelAnalysis();
        final original = f.state.uncertainAnalysisDiagnostic;
        expect(original, isNotNull);
        expect((original!.error as PlatformException).code, 'CANCEL_FAIL');
        await f.state.cancelAnalysis();
        expect(
          identical(f.state.uncertainAnalysisDiagnostic, original),
          isTrue,
        );
        await f.state.cancelAnalysis();
        expect(f.state.diagnosticError, isNull);
        expect(
          identical(f.state.uncertainAnalysisDiagnostic, original),
          isTrue,
        );
        await analysis.timeout(const Duration(seconds: 2));
        expect(f.state.hasUncertainAnalysis, isTrue);
        expect(
          identical(f.state.uncertainAnalysisDiagnostic, original),
          isTrue,
        );
        expect(f.state.project.candidates.single.note, 'keep');
        expect(f.state.canUndoReview, isTrue);
        expect(f.state.canStartAnalysis, isFalse);
        result.complete({'candidates': <Object>[]});
        await pumpEventQueue();
        expect(
          checks,
          1,
          reason: 'a settled run has one automatic status observer',
        );
        expect(
          identical(f.state.uncertainAnalysisDiagnostic, original),
          isTrue,
        );
        failCheck = false;
        expect(await f.state.checkUncertainAnalysis(), TaskStopStatus.running);
        expect(
          identical(f.state.uncertainAnalysisDiagnostic, original),
          isTrue,
        );
        active = false;
        expect(await f.state.checkUncertainAnalysis(), TaskStopStatus.stopped);
        expect(f.state.hasUncertainAnalysis, isFalse);
        expect(f.state.uncertainAnalysisDiagnostic, isNull);
        expect(f.state.canStartAnalysis, isTrue);
      } finally {
        if (!result.isCompleted) result.complete({'candidates': <Object>[]});
        messenger.setMockMethodCallHandler(analysisChannel, null);
        messenger.setMockMethodCallHandler(progressChannel, null);
        await f.close();
      }
    },
  );
  test(
    'confirmed stopped run is not marked again by its late startup timeout',
    () async {
      final f = MobileVideoFixture();
      final entered = Completer<void>(), result = Completer<Object?>();
      var checks = 0;
      messenger.setMockMethodCallHandler(progressChannel, (_) async => null);
      await f.init(
        engine: NativeAnalysisEngine(modelPreparer: () async => '/model'),
        analysisStartupTimeout: const Duration(milliseconds: 150),
      );
      try {
        final file = await f.file('original.mp4', 'original');
        f.state.project = f.project(file.path);
        messenger.setMockMethodCallHandler(analysisChannel, (call) async {
          if (call.method == 'analyzeVideo') {
            entered.complete();
            return result.future;
          }
          if (call.method == 'cancelAnalysis') {
            throw PlatformException(code: 'CANCEL_FAIL');
          }
          if (call.method == 'isAnalysisActive') {
            checks++;
            return false;
          }
          return null;
        });
        final analysis = f.state.startAnalysis();
        await entered.future;
        await f.state.cancelAnalysis();
        expect(f.state.hasUncertainAnalysis, isTrue);
        expect(await f.state.checkUncertainAnalysis(), TaskStopStatus.stopped);
        expect(f.state.hasUncertainAnalysis, isFalse);
        await analysis.timeout(const Duration(seconds: 2));
        expect(f.state.hasUncertainAnalysis, isFalse);
        result.complete({'candidates': <Object>[]});
        await pumpEventQueue();
        expect(checks, 1);
        expect(f.state.canStartAnalysis, isTrue);
      } finally {
        if (!result.isCompleted) result.complete({'candidates': <Object>[]});
        messenger.setMockMethodCallHandler(analysisChannel, null);
        messenger.setMockMethodCallHandler(progressChannel, null);
        await f.close();
      }
    },
  );
}
