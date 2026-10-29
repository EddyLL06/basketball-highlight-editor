// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:bhe_mobile/media_bridge.dart';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/diagnostics/mobile_diagnostics.dart'
    as diag;
import 'package:bhe_mobile/features/operation_status/task_stop_status.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/mobile_video_fixture.dart';
import 'seed_count.dart';

class Sink implements diag.DiagnosticBackend {
  final lines = <String>[];
  @override
  Future<void> initialize(String v, String l) async {}
  @override
  Future<void> append(String m, String? k) async {
    lines.add(m);
  }

  @override
  Future<diag.DiagnosticSnapshot> snapshot() async =>
      diag.DiagnosticSnapshot(lines: lines, available: true);
}

Future<void> waitFor(bool Function() ok, String label) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException(label);
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'committed result retains completion bookkeeping despite release failure',
    () async {
      final count = regressionSeedCount('P6_COMMITTED_COUNT');
      final outcomes = <Map<String, Object?>>[];
      const channel = MethodChannel('com.bhe.bhe/mobile_media'),
          paths = MethodChannel('plugins.flutter.io/path_provider');
      final previous = diag.MobileDiagnostics.instance;
      for (var seed = 0; seed < count; seed++) {
        final rng = Random(seed + 160000),
            kind = ['success', 'exception', 'late', 'never'][rng.nextInt(4)],
            merged = rng.nextInt(5) + 1;
        final f = MobileVideoFixture(),
            sink = Sink(),
            release = Completer<void>();
        final errors = <String>[];
        var init = false, calls = 0;
        String? resultPath;
        int? duration, diskDuration, actualMerged;
        bool? uncertain;
        String? visibleError;
        diag.MobileDiagnostics.instance = diag.MobileDiagnostics(sink);
        try {
          await f.init(
            exportEngine: NativeMediaExportEngine(
              drainTimeout: const Duration(milliseconds: 20),
            ),
            exportDrainTimeout: const Duration(milliseconds: 20),
          );
          init = true;
          final source = await f.file('original.mp4', 'original');
          f.state.project = f.project(source.path);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                if (call.method == 'registerMergeExport') return true;
                if (call.method == 'isExportActive') return false;
                if (call.method == 'mergeClips') {
                  calls++;
                  final p = File(
                    (call.arguments as Map)['outputPath'] as String,
                  );
                  await p.parent.create(recursive: true);
                  await p.writeAsString('committed-$seed');
                  return {
                    'outputPath': p.path,
                    'committed': true,
                    'mergedOverlapCount': merged,
                  };
                }
                if (call.method == 'releaseMergeExport') {
                  if (kind == 'success') return null;
                  if (kind == 'exception') {
                    throw PlatformException(code: 'RELEASE_ERROR');
                  }
                  if (kind == 'late') {
                    await Future<void>.delayed(
                      const Duration(milliseconds: 36),
                    );
                    return null;
                  }
                  await release.future;
                  return null;
                }
                return null;
              });
          await f.state.mergeClips().timeout(const Duration(seconds: 4));
          resultPath = f.state.exportedPaths.isEmpty
              ? null
              : f.state.exportedPaths.single;
          duration = f.state.project.lastExportDurationMs;
          actualMerged = f.state.exportMergedOverlapCount;
          visibleError = f.state.errorMessage;
          uncertain = f.state.hasUncertainExport;
          await Future<void>.delayed(Duration.zero);
          if (calls != 1 ||
              resultPath == null ||
              !await File(resultPath).exists()) {
            errors.add('committed file missing');
          }
          if (actualMerged != merged) {
            errors.add(
              'merged count lost expected=$merged actual=$actualMerged',
            );
          }
          if (duration == null) errors.add('export duration missing');
          final saved = const ProjectPackageCodec().decode(
            await File('${f.data.path}/projects/A.json').readAsString(),
          );
          diskDuration = saved.lastExportDurationMs;
          if (diskDuration != duration) {
            errors.add('export duration not persisted');
          }
          if (!sink.lines.any(
            (s) => s.contains('app event: operation.completed'),
          )) {
            errors.add('operation.completed missing');
          }
          if (visibleError != null) {
            errors.add('success has visible error $visibleError');
          }
          if (f.state.exportCancelled) {
            errors.add('committed export marked cancelled');
          }
          if (kind != 'success') {
            if (!f.state.hasUncertainExport) {
              errors.add('uncertain status missing');
            }
            if (await f.state.checkUncertainExport() !=
                TaskStopStatus.stopped) {
              errors.add('cleanup confirmation failed');
            }
            await waitFor(() => !f.state.hasUncertainExport, 'uncertain clear');
          }
          if (!release.isCompleted) release.complete();
          if (kind == 'late') {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        } catch (e, st) {
          errors.add('HARNESS $e\n$st');
        } finally {
          if (!release.isCompleted) release.complete();
          if (init) {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null);
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
          'kind': kind,
          'calls': calls,
          'expectedMerged': merged,
          'merged': actualMerged,
          'duration': duration,
          'diskDuration': diskDuration,
          'uncertain': uncertain,
          'error': visibleError,
          'completedEvent': sink.lines.any(
            (s) => s.contains('app event: operation.completed'),
          ),
          'errors': errors,
        });
      }
      diag.MobileDiagnostics.instance = previous;
      final failures = outcomes
          .where((x) => (x['errors'] as List).isNotEmpty)
          .toList();
      final p = Platform.environment['P6_COMMITTED_RESULTS'];
      if (p != null) {
        await File(p).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'base': 'current checkout',
            'outcomes': outcomes,
            'failures': failures,
          }),
        );
      }
      print('COMMITTED_SUMMARY count=$count failures=${failures.length}');
      if (failures.isNotEmpty) {
        print(
          'FAILING_SEEDS ${failures.map((failure) => failure['seed']).join(',')}\nFIRST ${jsonEncode(failures.first)}',
        );
      }
      expect(failures.length, 0);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
