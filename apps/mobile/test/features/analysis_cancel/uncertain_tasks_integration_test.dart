import 'dart:async';
import 'package:bhe_mobile/media_bridge.dart';
import 'package:bhe_mobile/features/operation_status/task_stop_status.dart';
import 'package:bhe_mobile/native_analysis_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const analysisChannel = MethodChannel('com.bhe.bhe/mobile_analysis');
  const progressChannel = MethodChannel('com.bhe.bhe/mobile_analysis_progress');
  const mediaChannel = MethodChannel('com.bhe.bhe/mobile_media');
  test(
    'project reset preserves uncertain analysis and blocks export',
    () async {
      final f = MobileVideoFixture();
      final analysisEntered = Completer<void>();
      final analysisResult = Completer<Object?>(),
          cancelResult = Completer<void>();
      var analysisActive = true, exports = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(progressChannel, (_) async => null);
      await f.init(
        engine: NativeAnalysisEngine(
          modelPreparer: () async => '/model',
          cancelTimeout: const Duration(milliseconds: 25),
        ),
        analysisStartupTimeout: const Duration(seconds: 2),
        analysisCancelTimeout: const Duration(milliseconds: 40),
        exportEngine: NativeMediaExportEngine(
          drainTimeout: const Duration(milliseconds: 30),
        ),
        exportDrainTimeout: const Duration(milliseconds: 30),
      );
      try {
        final file = await f.file('original.mp4', 'original');
        f.state.project = f.project(file.path);
        expect(await f.state.updateCandidateNote('goal', 'keep'), isTrue);
        messenger.setMockMethodCallHandler(analysisChannel, (call) async {
          if (call.method == 'analyzeVideo') {
            analysisEntered.complete();
            return analysisResult.future;
          }
          if (call.method == 'cancelAnalysis') {
            await cancelResult.future;
            return null;
          }
          if (call.method == 'isAnalysisActive') return analysisActive;
          return null;
        });
        messenger.setMockMethodCallHandler(mediaChannel, (call) async {
          if (call.method == 'registerMergeExport') return true;
          if (call.method == 'mergeClips') {
            exports++;
            return {'outputPath': 'out.mp4', 'committed': true};
          }
          return null;
        });
        final analysis = f.state.startAnalysis();
        await analysisEntered.future;
        await f.state.mergeClips();
        expect(exports, 0);
        await f.state.createNewProject();
        await analysis;
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(f.state.hasUncertainAnalysis, isTrue);
        expect(f.state.uncertainAnalysisDiagnostic, isNotNull);
        f.state.project = f.project(file.path, id: 'B');
        expect(f.state.canStartAnalysis, isFalse);
        expect(await f.state.checkUncertainAnalysis(), TaskStopStatus.running);
        analysisActive = false;
        expect(await f.state.checkUncertainAnalysis(), TaskStopStatus.stopped);
        await pumpEventQueue();
        expect(f.state.canStartAnalysis, isTrue);
        analysisResult.complete({'candidates': <Object>[]});
        cancelResult.complete();
        expect(f.state.project.id, 'B');
        expect(f.state.project.candidates.single.id, 'goal');
      } finally {
        if (!analysisResult.isCompleted) {
          analysisResult.complete({'candidates': <Object>[]});
        }
        if (!cancelResult.isCompleted) cancelResult.complete();
        messenger.setMockMethodCallHandler(analysisChannel, null);
        messenger.setMockMethodCallHandler(progressChannel, null);
        messenger.setMockMethodCallHandler(mediaChannel, null);
        await f.close();
      }
    },
  );
}
