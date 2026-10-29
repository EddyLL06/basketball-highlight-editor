// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_app_state.dart';
import 'package:bhe_mobile/media_bridge.dart';
import 'package:bhe_mobile/native_analysis_engine.dart';
import 'package:bhe_mobile/features/diagnostics/mobile_diagnostics.dart'
    as diag;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/mobile_video_fixture.dart';
import 'seed_count.dart';

class Sink implements diag.DiagnosticBackend {
  final lines = <String>[];
  @override
  Future<void> initialize(String a, String b) async {}
  @override
  Future<void> append(String m, String? k) async {
    lines.add(m);
  }

  @override
  Future<diag.DiagnosticSnapshot> snapshot() async =>
      diag.DiagnosticSnapshot(lines: lines, available: true);
}

Future<void> waitFor(bool Function() ok, String label) async {
  final until = DateTime.now().add(const Duration(seconds: 5));
  while (!ok()) {
    if (DateTime.now().isAfter(until)) throw TimeoutException(label);
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

String stateValue(MobileAppState s) => jsonEncode({
  'progress': s.progress,
  'message': s.progressMessage,
  'error': s.errorMessage,
  'diagnostic': s.diagnosticError?.error.toString(),
  'candidates': [for (final c in s.project.candidates) c.toJson()],
  'undo': s.canUndoReview,
});
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'analysis/export exclusion survives controlled randomized interleavings',
    () async {
      final count = regressionSeedCount('P6_EXCLUSION_COUNT'),
          start =
              int.tryParse(Platform.environment['P6_EXCLUSION_START'] ?? '') ??
              0;
      final outcomes = <Map<String, Object?>>[];
      final coverage = <String, int>{}, reasons = <String, int>{};
      const analysis = MethodChannel('com.bhe.bhe/mobile_analysis'),
          events = MethodChannel('com.bhe.bhe/mobile_analysis_progress'),
          media = MethodChannel('com.bhe.bhe/mobile_media'),
          paths = MethodChannel('plugins.flutter.io/path_provider');
      final previous = diag.MobileDiagnostics.instance;
      for (var seed = start; seed < start + count; seed++) {
        final rng = Random(seed + 210000),
            phase = [
              'prep',
              'analysis',
              'merge',
              'separate',
              'cleanup',
              'album',
            ][rng.nextInt(6)],
            ack = ['ok', 'fail', 'delay'][rng.nextInt(3)],
            query = ['running', 'unknown', 'failure'][rng.nextInt(3)],
            switchProject = rng.nextBool();
        final f = MobileVideoFixture(),
            sink = Sink(),
            entered = Completer<void>(),
            model = Completer<String>(),
            analysisResult = Completer<Object?>(),
            exportResult = Completer<Object?>(),
            cleanup = Completer<void>(),
            album = Completer<void>();
        final errors = <String>[], trace = <String>[];
        var initialized = false,
            analysisCalls = 0,
            exportCalls = 0,
            albumCalls = 0,
            analysisActive = 0,
            exportActive = 0,
            maxOverlap = 0,
            preparations = 0;
        bool activeStatus = true, firstExport = true;
        Future<void>? running;
        coverage['phase:$phase'] = (coverage['phase:$phase'] ?? 0) + 1;
        coverage['ack:$ack'] = (coverage['ack:$ack'] ?? 0) + 1;
        diag.MobileDiagnostics.instance = diag.MobileDiagnostics(sink);
        try {
          final engine = NativeAnalysisEngine(
            modelPreparer: () {
              preparations++;
              if (phase == 'prep' && preparations == 1) {
                entered.complete();
                return model.future;
              }
              return Future.value('/model-$preparations');
            },
          );
          await f.init(
            engine: engine,
            exportEngine: NativeMediaExportEngine(
              drainTimeout: const Duration(milliseconds: 35),
            ),
            exportDrainTimeout: const Duration(milliseconds: 25),
            exportCancelTimeout: const Duration(milliseconds: 40),
            analysisCancelTimeout: const Duration(milliseconds: 40),
            analysisStartupTimeout: const Duration(seconds: 5),
          );
          initialized = true;
          final video = await f.file('original.mp4', 'original');
          f.state.project = f.project(video.path);
          if (!await f.state.updateCandidateNote('goal', 'keep')) {
            throw StateError('baseline review failed');
          }
          f.state.exportedPaths = ['/fake-export.mp4'];
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(events, (_) async => null);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(analysis, (call) async {
                if (call.method == 'analyzeVideo') {
                  analysisCalls++;
                  analysisActive++;
                  if (exportActive > 0) maxOverlap++;
                  if (phase == 'analysis' && analysisCalls == 1) {
                    entered.complete();
                    try {
                      return await analysisResult.future;
                    } finally {
                      analysisActive--;
                    }
                  }
                  analysisActive--;
                  return {'candidates': <Object>[]};
                }
                if (call.method == 'cancelAnalysis') {
                  coverage['native-analysis-cancel:$ack'] =
                      (coverage['native-analysis-cancel:$ack'] ?? 0) + 1;
                  if (ack == 'delay') {
                    await Future<void>.delayed(const Duration(milliseconds: 6));
                  }
                  if (ack == 'fail') {
                    throw PlatformException(code: 'ANALYSIS_CANCEL_FAIL');
                  }
                  return null;
                }
                if (call.method == 'isAnalysisActive') {
                  final key =
                      'native-analysis-status:${activeStatus ? query : 'stopped'}';
                  coverage[key] = (coverage[key] ?? 0) + 1;
                  if (!activeStatus) return false;
                  if (query == 'running') return true;
                  if (query == 'unknown') return null;
                  throw PlatformException(code: 'QUERY_FAIL');
                }
                return null;
              });
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(media, (call) async {
                if (call.method == 'registerMergeExport') return true;
                if (call.method == 'isExportActive') {
                  final key =
                      'native-export-status:${activeStatus ? query : 'stopped'}';
                  coverage[key] = (coverage[key] ?? 0) + 1;
                  if (!activeStatus) return false;
                  if (query == 'running') return true;
                  if (query == 'unknown') return null;
                  throw PlatformException(code: 'QUERY_FAIL');
                }
                if (call.method == 'cancelExport') {
                  coverage['native-export-cancel:$ack'] =
                      (coverage['native-export-cancel:$ack'] ?? 0) + 1;
                  if (ack == 'delay') {
                    await Future<void>.delayed(const Duration(milliseconds: 6));
                  }
                  if (ack == 'fail') {
                    throw PlatformException(code: 'EXPORT_CANCEL_FAIL');
                  }
                  return null;
                }
                if (call.method == 'saveToLibrary') {
                  albumCalls++;
                  exportActive++;
                  if (analysisActive > 0) maxOverlap++;
                  if (phase == 'album' && albumCalls == 1) {
                    entered.complete();
                    try {
                      await album.future;
                    } finally {
                      exportActive--;
                    }
                  } else {
                    exportActive--;
                  }
                  return null;
                }
                if (call.method == 'releaseMergeExport' &&
                    phase == 'cleanup' &&
                    !entered.isCompleted) {
                  exportActive++;
                  entered.complete();
                  try {
                    await cleanup.future;
                  } finally {
                    exportActive--;
                  }
                  return null;
                }
                if (call.method == 'mergeClips' ||
                    call.method == 'exportClip') {
                  exportCalls++;
                  exportActive++;
                  if (analysisActive > 0) maxOverlap++;
                  if ((phase == 'merge' || phase == 'separate') &&
                      firstExport) {
                    firstExport = false;
                    entered.complete();
                    try {
                      return await exportResult.future;
                    } finally {
                      exportActive--;
                    }
                  }
                  exportActive--;
                  return {'outputPath': 'out.mp4', 'committed': true};
                }
                return null;
              });
          switch (phase) {
            case 'prep':
            case 'analysis':
              running = f.state.startAnalysis();
            case 'merge':
            case 'cleanup':
              running = f.state.mergeClips();
            case 'separate':
              running = f.state.exportClips();
            case 'album':
              running = f.state.saveExportedFiles();
          }
          await entered.future.timeout(const Duration(seconds: 5));
          trace.add('start $phase');
          if (phase == 'cleanup' && rng.nextBool()) {
            coverage['cleanup:early'] = (coverage['cleanup:early'] ?? 0) + 1;
            trace.add('cleanup reply before next action');
            cleanup.complete();
            await running!.timeout(const Duration(seconds: 7));
            final before = analysisCalls;
            await f.state.startAnalysis().timeout(const Duration(seconds: 7));
            if (analysisCalls != before + 1) {
              errors.add('analysis not admitted after early cleanup');
            }
            if (maxOverlap > 0) errors.add('native analysis/export overlap');
          } else {
            if (phase == 'cleanup') {
              coverage['cleanup:late'] = (coverage['cleanup:late'] ?? 0) + 1;
            }
            if (phase != 'album' && phase != 'cleanup') {
              f.state.exportedPaths = ['/fake-export.mp4'];
            }
            Future<void> rejected(String action) async {
              final before = stateValue(f.state),
                  logCount = sink.lines.length,
                  a = analysisCalls,
                  e = exportCalls,
                  l = albumCalls;
              final reason = action == 'analysis'
                  ? f.state.analysisStartBlockReason
                  : f.state.exportStartBlockReason;
              if (reason == null) {
                errors.add('no block reason for $action');
                return;
              }
              reasons[reason] = (reasons[reason] ?? 0) + 1;
              coverage['rejected:$action'] =
                  (coverage['rejected:$action'] ?? 0) + 1;
              trace.add('rejected $action: $reason');
              switch (action) {
                case 'analysis':
                  await f.state.startAnalysis();
                case 'merge':
                  await f.state.mergeClips();
                case 'separate':
                  await f.state.exportClips();
                case 'album':
                  await f.state.saveExportedFiles();
              }
              if (stateValue(f.state) != before) {
                errors.add('rejected $action mutated active state');
              }
              if (sink.lines.length != logCount) {
                errors.add(
                  'rejected $action added diagnostics: ${sink.lines.skip(logCount).toList()}',
                );
              }
              if (analysisCalls != a || exportCalls != e || albumCalls != l) {
                errors.add('rejected $action dispatched native');
              }
            }

            final allowed = phase == 'prep' || phase == 'analysis'
                ? ['merge', 'separate', 'album', 'analysis']
                : ['analysis', 'merge', 'separate', 'album'];
            final steps = 2 + rng.nextInt(4);
            for (var i = 0; i < steps; i++) {
              await rejected(allowed[rng.nextInt(allowed.length)]);
            }
            if ((phase == 'merge' ||
                    phase == 'separate' ||
                    phase == 'cleanup') &&
                switchProject) {
              await f.state.createNewProject();
              f.state.project = f.project(video.path, id: 'B');
              f.state.exportedPaths = ['/fake-export.mp4'];
              trace.add('switch B');
              if (rng.nextBool()) {
                await f.state.openProject('A');
                trace.add('return A');
                f.state.exportedPaths = ['/fake-export.mp4'];
                coverage['project-roundtrip'] =
                    (coverage['project-roundtrip'] ?? 0) + 1;
              }
              await Future<void>.delayed(const Duration(milliseconds: 40));
              await rejected('analysis');
            }
            if (phase == 'prep' || phase == 'analysis') {
              final saved = const ProjectPackageCodec().decode(
                await File('${f.data.path}/projects/A.json').readAsString(),
              );
              if (saved.candidates.length != 1 ||
                  saved.candidates.single.note != 'keep' ||
                  !f.state.canUndoReview) {
                errors.add('review lost before cancellation');
              }
            }
            final exitedEarly =
                rng.nextBool() &&
                !switchProject &&
                (phase == 'analysis' ||
                    phase == 'merge' ||
                    phase == 'separate');
            if (exitedEarly) {
              activeStatus = false;
              if (phase == 'analysis') {
                analysisResult.complete({'candidates': <Object>[]});
              } else {
                exportResult.complete({
                  'outputPath': 'out.mp4',
                  'committed': true,
                });
              }
              await running!.timeout(const Duration(seconds: 7));
              trace.add('native exits before cancellation');
              coverage['exit:early'] = (coverage['exit:early'] ?? 0) + 1;
              if (phase == 'analysis') {
                await f.state.cancelAnalysis();
              } else {
                await f.state.cancelExport();
              }
            } else if (phase == 'prep' || phase == 'analysis') {
              if (phase == 'analysis') {
                coverage['exit:late'] = (coverage['exit:late'] ?? 0) + 1;
              }
              await f.state.cancelAnalysis();
              trace.add('cancel analysis $ack');
              if (phase == 'analysis' && ack != 'fail') {
                await waitFor(
                  () => f.state.hasUncertainAnalysis,
                  'uncertain analysis',
                );
                final observed = await f.state.checkUncertainAnalysis();
                final expected = query == 'running'
                    ? TaskStopStatus.running
                    : TaskStopStatus.unknown;
                if (observed != expected) {
                  errors.add(
                    'analysis status expected=$expected actual=$observed',
                  );
                }
                coverage['analysis-query:$query'] =
                    (coverage['analysis-query:$query'] ?? 0) + 1;
                await rejected('merge');
              }
              if (phase == 'analysis' && ack == 'fail') {
                if (!f.state.analysing || f.state.diagnosticError == null) {
                  errors.add('cancel failure not visible');
                }
                await rejected('merge');
              }
              if (!model.isCompleted) model.complete('/old-model');
              if (!analysisResult.isCompleted) {
                activeStatus = false;
                analysisResult.complete({'candidates': <Object>[]});
              }
            } else if (phase == 'merge' || phase == 'separate') {
              coverage['exit:late'] = (coverage['exit:late'] ?? 0) + 1;
              if (!switchProject) {
                await f.state.cancelExport();
                trace.add('cancel export $ack');
              }
              await waitFor(
                () => f.state.hasUncertainExport,
                'uncertain export',
              );
              final observed = await f.state.checkUncertainExport();
              final expected = query == 'running'
                  ? TaskStopStatus.running
                  : TaskStopStatus.unknown;
              if (observed != expected) {
                errors.add('export status expected=$expected actual=$observed');
              }
              await Future<void>.delayed(const Duration(milliseconds: 2));
              coverage['export-query:$query'] =
                  (coverage['export-query:$query'] ?? 0) + 1;
              await rejected('analysis');
              activeStatus = false;
              if (!exportResult.isCompleted) {
                exportResult.completeError(
                  PlatformException(code: 'EXPORT_CANCELLED'),
                );
              }
            } else if (phase == 'cleanup') {
              if (!cleanup.isCompleted) cleanup.complete();
            } else if (phase == 'album') {
              if (!album.isCompleted) album.complete();
            }
            await running!.timeout(const Duration(seconds: 7));
            await f.state.pendingProjectWrites.timeout(
              const Duration(seconds: 7),
            );
            if (f.state.hasUncertainAnalysis) {
              activeStatus = false;
              final result = await f.state.checkUncertainAnalysis();
              coverage['recovery-analysis:${result.name}'] =
                  (coverage['recovery-analysis:${result.name}'] ?? 0) + 1;
            }
            if (f.state.hasUncertainExport) {
              activeStatus = false;
              final result = await f.state.checkUncertainExport();
              coverage['recovery-export:${result.name}'] =
                  (coverage['recovery-export:${result.name}'] ?? 0) + 1;
            }
            await waitFor(
              () =>
                  !f.state.hasUncertainAnalysis && !f.state.hasUncertainExport,
              'uncertain recovery',
            );
            if (phase == 'prep' || phase == 'analysis') {
              if (!exitedEarly &&
                  (phase == 'prep' || ack != 'fail') &&
                  (f.state.project.candidates.length != 1 ||
                      f.state.project.candidates.single.note != 'keep' ||
                      !f.state.canUndoReview)) {
                errors.add('review or undo lost before native started');
              }
              if (f.state.project.candidates.isEmpty &&
                  phase == 'analysis' &&
                  (ack == 'fail' || exitedEarly)) {
                if (!await f.state.addCandidate(
                  f.project(video.path).candidates.single,
                )) {
                  throw StateError(
                    'could not seed candidate after completed analysis',
                  );
                }
              }
              final before = exportCalls;
              await f.state.mergeClips().timeout(const Duration(seconds: 7));
              if (exportCalls != before + 1) {
                errors.add('export retry blocked after recovery');
              }
            } else {
              final before = analysisCalls;
              await f.state.startAnalysis().timeout(const Duration(seconds: 7));
              if (analysisCalls != before + 1) {
                errors.add('analysis retry blocked after recovery');
              }
            }
            if (maxOverlap > 0) errors.add('native analysis/export overlap');
          }
        } catch (e, st) {
          errors.add('HARNESS $e\n$st');
        } finally {
          if (!model.isCompleted) model.complete('/model');
          if (!analysisResult.isCompleted) {
            analysisResult.complete({'candidates': <Object>[]});
          }
          if (!exportResult.isCompleted) {
            exportResult.complete({
              'outputPath': 'unused.mp4',
              'committed': true,
            });
          }
          if (!cleanup.isCompleted) cleanup.complete();
          if (!album.isCompleted) album.complete();
          activeStatus = false;
          try {
            if (running != null) {
              await running.timeout(const Duration(seconds: 5));
            }
          } catch (e) {
            errors.add('HARNESS drain $e');
          }
          if (initialized) {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(analysis, null);
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(events, null);
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(media, null);
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(paths, (_) async => f.root.path);
            try {
              await f.close();
            } catch (e) {
              errors.add('HARNESS close $e');
            }
          }
        }
        outcomes.add({
          'seed': seed,
          'phase': phase,
          'ack': ack,
          'query': query,
          'switch': switchProject,
          'analysisCalls': analysisCalls,
          'exportCalls': exportCalls,
          'albumCalls': albumCalls,
          'overlaps': maxOverlap,
          'trace': trace,
          'errors': errors,
        });
      }
      diag.MobileDiagnostics.instance = previous;
      final failures = outcomes
          .where((x) => (x['errors'] as List).isNotEmpty)
          .toList();
      final path = Platform.environment['P6_EXCLUSION_RESULT'];
      if (path != null) {
        await File(path).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'base': 'current checkout',
            'outcomes': outcomes,
            'failures': failures,
            'coverage': coverage,
            'reasons': reasons,
          }),
        );
      }
      print(
        'EXCLUSION_SUMMARY count=$count failures=${failures.length} coverage=$coverage reasons=$reasons',
      );
      if (failures.isNotEmpty) {
        print(
          'FAILING_SEEDS ${failures.map((failure) => failure['seed']).join(',')}\nFIRST ${jsonEncode(failures.first)}',
        );
      }
      expect(failures.length, 0);
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
