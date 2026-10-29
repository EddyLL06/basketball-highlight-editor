import 'dart:async';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';

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
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  for (final progressFirst in [false, true]) {
    for (final outcome in ['success', 'failure', 'timeout']) {
      test(
        '${progressFirst ? 'after' : 'before'} progress: cancel $outcome, switch and late result',
        () async {
          final f = MobileVideoFixture();
          final started = Completer<void>(),
              nativeResult = Completer<Object?>();
          final cancelResult = Completer<void>();
          var active = true, starts = 0, exports = 0;
          messenger.setMockMethodCallHandler(
            progressChannel,
            (_) async => null,
          );
          await f.init(
            engine: NativeAnalysisEngine(
              modelPreparer: () async => '/model',
              cancelTimeout: const Duration(milliseconds: 35),
            ),
            analysisStartupTimeout: const Duration(seconds: 3),
            analysisCancelTimeout: const Duration(milliseconds: 60),
          );
          try {
            final video = await f.file('original.mp4', 'original');
            f.state.project = f.project(video.path);
            expect(await f.state.updateCandidateNote('goal', 'keep'), isTrue);
            messenger.setMockMethodCallHandler(analysisChannel, (call) async {
              if (call.method == 'analyzeVideo') {
                starts++;
                if (starts == 1) {
                  started.complete();
                  return nativeResult.future;
                }
                return {'candidates': <Object>[]};
              }
              if (call.method == 'cancelAnalysis') {
                if (outcome == 'failure') {
                  throw PlatformException(code: 'CANCEL_FAIL');
                }
                if (outcome == 'timeout') await cancelResult.future;
                return null;
              }
              if (call.method == 'isAnalysisActive') return active;
              return null;
            });
            messenger.setMockMethodCallHandler(mediaChannel, (call) async {
              if (call.method == 'registerMergeExport') return true;
              if (call.method == 'mergeClips') {
                exports++;
                return {'outputPath': 'out.mp4', 'committed': true};
              }
              if (call.method == 'exportClip') exports++;
              return null;
            });
            final running = f.state.startAnalysis();
            await started.future;
            if (progressFirst) {
              final event = const StandardMethodCodec().encodeSuccessEnvelope({
                'stage': 'refineCandidates',
                'progress': 0.4,
                'message': 'native progress',
              });
              await messenger.handlePlatformMessage(
                progressChannel.name,
                event,
                (_) {},
              );
              for (
                var i = 0;
                i < 100 && f.state.project.lastAnalysisStatus != 'running';
                i++
              ) {
                await Future<void>.delayed(const Duration(milliseconds: 5));
              }
              expect(f.state.project.lastAnalysisStatus, 'running');
            }
            await f.state.createNewProject();
            expect(f.state.hasUncertainAnalysis, isTrue);
            if (!progressFirst) {
              final oldProject = const ProjectPackageCodec().decode(
                await File('${f.data.path}/projects/A.json').readAsString(),
              );
              expect(oldProject.candidates.single.note, 'keep');
            }
            if (outcome != 'success') {
              expect(f.state.uncertainAnalysisDiagnostic, isNotNull);
            }
            final newId = f.state.project.id;
            f.state.project = f.project(video.path, id: newId);
            expect(f.state.canStartAnalysis, isFalse);
            await f.state.startAnalysis();
            await f.state.mergeClips();
            await f.state.exportClips();
            expect(starts, 1);
            expect(exports, 0);
            expect(f.state.exportStartBlockReason, '上次任务尚未确认结束，请先确认停止。');
            if (!progressFirst) {
              expect(f.state.project.candidates.single.note, isNull);
            }
            nativeResult.complete({'candidates': <Object>[]});
            await running;
            await pumpEventQueue();
            expect(f.state.hasUncertainAnalysis, isTrue);
            expect(
              await f.state.checkUncertainAnalysis(),
              TaskStopStatus.running,
            );
            expect(f.state.project.id, newId);
            expect(f.state.project.candidates.single.id, 'goal');
            active = false;
            expect(
              await f.state.checkUncertainAnalysis(),
              TaskStopStatus.stopped,
            );
            expect(f.state.hasUncertainAnalysis, isFalse);
            await f.state.mergeClips();
            expect(exports, 1);
            await f.state.startAnalysis();
            expect(starts, 2);
          } finally {
            if (!nativeResult.isCompleted) {
              nativeResult.complete({'candidates': <Object>[]});
            }
            if (!cancelResult.isCompleted) cancelResult.complete();
            await pumpEventQueue();
            messenger.setMockMethodCallHandler(analysisChannel, null);
            messenger.setMockMethodCallHandler(progressChannel, null);
            messenger.setMockMethodCallHandler(mediaChannel, null);
            await f.close();
          }
        },
      );
    }
  }
}
