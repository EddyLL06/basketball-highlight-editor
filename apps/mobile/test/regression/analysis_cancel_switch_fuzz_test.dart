// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:bhe_mobile/mobile_app_state.dart';
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

Future<void> until(bool Function() ok, String label) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException(label);
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

String review(MobileAppState s) =>
    jsonEncode([for (final c in s.project.candidates) c.toJson()]);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cancel/switch with delayed worker result and task exclusion',
    () async {
      final start =
              int.tryParse(Platform.environment['FINAL_CANCEL_START'] ?? '') ??
              0,
          count = regressionSeedCount('FINAL_CANCEL_COUNT');
      final all = <Map<String, Object?>>[];
      final previous = diag.MobileDiagnostics.instance;
      const analysis = MethodChannel('com.bhe.bhe/mobile_analysis'),
          events = MethodChannel('com.bhe.bhe/mobile_analysis_progress'),
          media = MethodChannel('com.bhe.bhe/mobile_media'),
          paths = MethodChannel('plugins.flutter.io/path_provider');
      for (var seed = start; seed < start + count; seed++) {
        final rng = Random(seed + 310000),
            outcome = ['success', 'failure', 'timeout'][rng.nextInt(3)],
            progress = rng.nextBool(),
            roundtrip = rng.nextBool(),
            retry = ['analysis', 'merge', 'separate', 'album'][rng.nextInt(4)];
        final f = MobileVideoFixture(),
            sink = Sink(),
            entered = Completer<void>(),
            nativeResult = Completer<Object?>(),
            cancelReply = Completer<void>();
        final errors = <String>[],
            diagnosticIssues = <String>[],
            trace = <String>[];
        var init = false,
            analysisCalls = 0,
            exportCalls = 0,
            albumCalls = 0,
            aActive = 0,
            eActive = 0,
            overlaps = 0,
            statusChecks = 0;
        var startupDiagnosticChecked = false, observerChecked = false;
        bool workerActive = true;
        Future<void>? running;
        diag.MobileDiagnostics.instance = diag.MobileDiagnostics(sink);
        try {
          final engine = NativeAnalysisEngine(
            modelPreparer: () async => '/model',
            cancelTimeout: const Duration(milliseconds: 30),
          );
          await f.init(
            engine: engine,
            analysisStartupTimeout: outcome == 'failure' && !progress
                ? const Duration(milliseconds: 120)
                : const Duration(seconds: 3),
            analysisCancelTimeout: const Duration(milliseconds: 50),
          );
          init = true;
          final video = await f.file('original.mp4', 'original');
          f.state.project = f.project(video.path);
          if (!await f.state.updateCandidateNote('goal', 'keep')) {
            throw StateError('baseline review failed');
          }
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(events, (_) async => null);
          messenger.setMockMethodCallHandler(analysis, (call) async {
            if (call.method == 'analyzeVideo') {
              analysisCalls++;
              aActive++;
              if (eActive > 0) overlaps++;
              if (analysisCalls == 1) {
                entered.complete();
                try {
                  return await nativeResult.future;
                } finally {
                  aActive--;
                }
              }
              aActive--;
              return {'candidates': <Object>[]};
            }
            if (call.method == 'cancelAnalysis') {
              if (outcome == 'failure') {
                throw PlatformException(code: 'CANCEL_FAIL');
              }
              if (outcome == 'timeout') await cancelReply.future;
              return null;
            }
            if (call.method == 'isAnalysisActive') {
              statusChecks++;
              return workerActive;
            }
            return null;
          });
          messenger.setMockMethodCallHandler(media, (call) async {
            if (call.method == 'registerMergeExport') return true;
            if (call.method == 'mergeClips' || call.method == 'exportClip') {
              exportCalls++;
              eActive++;
              if (aActive > 0) overlaps++;
              eActive--;
              return {'outputPath': 'out.mp4', 'committed': true};
            }
            if (call.method == 'saveToLibrary') {
              albumCalls++;
              eActive++;
              if (aActive > 0) overlaps++;
              eActive--;
              return null;
            }
            return null;
          });
          running = f.state.startAnalysis();
          await entered.future.timeout(const Duration(seconds: 5));
          trace.add('native started');
          if (progress) {
            final data = const StandardMethodCodec().encodeSuccessEnvelope({
              'stage': 'refineCandidates',
              'progress': 0.4,
              'message': 'running',
            });
            await messenger.handlePlatformMessage(events.name, data, (_) {});
            await until(
              () => f.state.project.lastAnalysisStatus == 'running',
              'first progress commit',
            );
            trace.add('first progress');
          }
          if (outcome == 'failure' && !progress) {
            await f.state.cancelAnalysis();
            final original = f.state.uncertainAnalysisDiagnostic;
            if (original == null ||
                original.error is! PlatformException ||
                (original.error as PlatformException).code != 'CANCEL_FAIL') {
              diagnosticIssues.add(
                'cancel failure diagnostic absent or incorrect',
              );
            }
            await running.timeout(const Duration(seconds: 5));
            if (!identical(original, f.state.uncertainAnalysisDiagnostic)) {
              diagnosticIssues.add(
                'startup timeout replaced cancellation failure',
              );
            }
            startupDiagnosticChecked = true;
          }
          await f.state.createNewProject().timeout(const Duration(seconds: 5));
          trace.add('switch B');
          if (!f.state.hasUncertainAnalysis) {
            errors.add('worker uncertainty lost after switch');
          }
          final id = f.state.project.id;
          f.state.project = f.project(video.path, id: id);
          f.state.exportedPaths = ['/fake'];
          if (roundtrip) {
            await f.state.openProject('A');
            await f.state.createNewProject();
            final nextId = f.state.project.id;
            f.state.project = f.project(video.path, id: nextId);
            f.state.exportedPaths = ['/fake'];
            trace.add('roundtrip A/new');
            if (!f.state.hasUncertainAnalysis) {
              errors.add('uncertainty lost during roundtrip');
            }
          }
          if (!await f.state.renameProject('Target')) {
            throw StateError('new project baseline save failed');
          }
          final targetFile = File(
            '${f.data.path}/projects/${f.state.project.id}.json',
          );
          final diskBefore = await targetFile.readAsString();
          final before = review(f.state),
              baselineDiag = f.state.uncertainAnalysisDiagnostic;
          final actions = ['analysis', 'merge', 'separate', 'album'];
          actions.shuffle(rng);
          final n = 2 + rng.nextInt(3);
          for (var i = 0; i <= n; i++) {
            final action = actions[i % n],
                a = analysisCalls,
                e = exportCalls,
                al = albumCalls;
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
            trace.add('blocked $action');
            if (a != analysisCalls || e != exportCalls || al != albumCalls) {
              errors.add('blocked $action reached native');
            }
            if (review(f.state) != before) {
              errors.add('blocked $action changed review');
            }
            if (baselineDiag != null &&
                !identical(baselineDiag, f.state.uncertainAnalysisDiagnostic)) {
              diagnosticIssues.add(
                'uncertain diagnostic replaced after blocked $action',
              );
            }
          }
          final checksBeforeLate = statusChecks;
          nativeResult.complete({
            'candidates': [
              {
                'id': 'late-old',
                'start_ms': 0,
                'end_ms': 1000,
                'event_ms': 500,
              },
            ],
          });
          await running.timeout(const Duration(seconds: 5));
          await until(
            () => statusChecks > checksBeforeLate,
            'automatic status observer',
          );
          await Future<void>.delayed(const Duration(milliseconds: 5));
          if (statusChecks != checksBeforeLate + 1) {
            diagnosticIssues.add(
              'automatic status observer count ${statusChecks - checksBeforeLate}, expected 1',
            );
          }
          observerChecked = true;
          trace.add('old result delivered, native still reports active');
          if (review(f.state) != before) {
            errors.add('late result changed current review');
          }
          if (await targetFile.readAsString() != diskBefore) {
            errors.add('late result changed current project JSON');
          }
          if (!f.state.hasUncertainAnalysis) {
            errors.add('unconfirmed worker admitted after late result');
          }
          await f.state.mergeClips();
          if (exportCalls != 0) {
            errors.add('export admitted while native still active');
          }
          workerActive = false;
          for (var k = 0; k < 20 && f.state.hasUncertainAnalysis; k++) {
            await f.state.checkUncertainAnalysis();
            await Future<void>.delayed(const Duration(milliseconds: 3));
          }
          if (f.state.hasUncertainAnalysis) {
            errors.add('confirmed exit did not recover');
          }
          final aa = analysisCalls, ee = exportCalls, ll = albumCalls;
          switch (retry) {
            case 'analysis':
              await f.state.startAnalysis();
            case 'merge':
              await f.state.mergeClips();
            case 'separate':
              await f.state.exportClips();
            case 'album':
              await f.state.saveExportedFiles();
          }
          if (retry == 'analysis' && analysisCalls != aa + 1) {
            errors.add('analysis retry failed');
          }
          if ((retry == 'merge' || retry == 'separate') &&
              exportCalls != ee + 1) {
            errors.add('export retry failed');
          }
          if (retry == 'album' && albumCalls != ll + 1) {
            errors.add('album retry failed');
          }
          if (overlaps > 0) errors.add('native analysis/export overlap');
        } catch (e, st) {
          errors.add('HARNESS $e\n$st');
        } finally {
          if (!nativeResult.isCompleted) {
            nativeResult.complete({'candidates': <Object>[]});
          }
          if (!cancelReply.isCompleted) cancelReply.complete();
          try {
            if (running != null) {
              await running.timeout(const Duration(seconds: 5));
            }
          } catch (e) {
            errors.add('HARNESS drain $e');
          }
          if (init) {
            final m = TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger;
            m.setMockMethodCallHandler(analysis, null);
            m.setMockMethodCallHandler(events, null);
            m.setMockMethodCallHandler(media, null);
            m.setMockMethodCallHandler(paths, (_) async => f.root.path);
            try {
              await f.close();
            } catch (e) {
              errors.add('HARNESS close $e');
            }
          }
        }
        all.add({
          'seed': seed,
          'outcome': outcome,
          'progress': progress,
          'roundtrip': roundtrip,
          'retry': retry,
          'analysisCalls': analysisCalls,
          'exportCalls': exportCalls,
          'albumCalls': albumCalls,
          'overlaps': overlaps,
          'startupDiagnosticChecked': startupDiagnosticChecked,
          'observerChecked': observerChecked,
          'statusChecks': statusChecks,
          'trace': trace,
          'diagnosticIssues': diagnosticIssues,
          'errors': errors,
        });
      }
      diag.MobileDiagnostics.instance = previous;
      final failures = all
          .where((x) => (x['errors'] as List).isNotEmpty)
          .toList();
      final diagnostic = all
          .where((x) => (x['diagnosticIssues'] as List).isNotEmpty)
          .toList();
      final p = Platform.environment['FINAL_CANCEL_RESULT'];
      if (p != null) {
        await File(p).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'base': 'current checkout',
            'outcomes': all,
            'failures': failures,
            'diagnosticIssues': diagnostic,
          }),
        );
      }
      print(
        'FINAL_CANCEL_SUMMARY count=$count failures=${failures.length} diagnostic=${diagnostic.length}',
      );
      if (failures.isNotEmpty) {
        print(
          'FAILING_SEEDS ${failures.map((failure) => failure['seed']).join(',')}\nFIRST ${jsonEncode(failures.first)}',
        );
      }
      if (diagnostic.isNotEmpty) {
        print(
          'DIAGNOSTIC_SEEDS ${diagnostic.map((failure) => failure['seed']).join(',')}\nFIRST_DIAGNOSTIC ${jsonEncode(diagnostic.first)}',
        );
      }
      expect(failures.length, 0);
      expect(diagnostic.length, 0);
      // A single reproduced seed may not select the diagnostic scenario.
      if (start == 0 && count >= 30) {
        expect(
          all.where((x) => x['startupDiagnosticChecked'] == true).length,
          greaterThan(0),
        );
      }
      expect(all.where((x) => x['observerChecked'] == true).length, count);
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
