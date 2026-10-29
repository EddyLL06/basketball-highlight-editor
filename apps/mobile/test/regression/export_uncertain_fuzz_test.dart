// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:bhe_mobile/media_bridge.dart';
import 'package:bhe_mobile/features/operation_status/task_stop_status.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/mobile_video_fixture.dart';
import 'seed_count.dart';

Future<void> waitFor(bool Function() ok, String label) async {
  final end = DateTime.now().add(const Duration(seconds: 4));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException(label);
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.bhe.bhe/mobile_media'),
      pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  test(
    'uncertain card admits only an authoritative cleaned result',
    () async {
      final count = regressionSeedCount('P6_UNCERTAIN_COUNT');
      final outcomes = <Map<String, Object?>>[];
      for (var seed = 0; seed < count; seed++) {
        final rng = Random(seed + 110000),
            status = [
              'cleaned',
              'running',
              'unknown',
              'failure',
            ][rng.nextInt(4)],
            mode = rng.nextBool() ? 'merge' : 'separate',
            stopFirst = rng.nextBool();
        final f = MobileVideoFixture(),
            entered = Completer<void>(),
            oldResult = Completer<Object?>();
        final errors = <String>[];
        var init = false, calls = 0, queries = 0;
        bool cleanupOverride = false;
        Future<void>? old;
        try {
          await f.init(
            exportEngine: NativeMediaExportEngine(
              drainTimeout: const Duration(milliseconds: 25),
            ),
            exportDrainTimeout: const Duration(milliseconds: 20),
            exportCancelTimeout: const Duration(milliseconds: 50),
          );
          init = true;
          final video = await f.file('original.mp4', 'original');
          f.state.project = f.project(video.path);
          if (!await f.state.renameProject('Baseline')) {
            throw StateError('baseline failed');
          }
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                if (call.method == 'registerMergeExport') return true;
                if (call.method == 'isExportActive') {
                  queries++;
                  if (cleanupOverride || status == 'cleaned') return false;
                  if (status == 'running') return true;
                  if (status == 'unknown') return null;
                  throw PlatformException(code: 'QUERY_FAILED');
                }
                if (call.method == 'mergeClips' ||
                    call.method == 'exportClip') {
                  calls++;
                  if (calls == 1) {
                    entered.complete();
                    return oldResult.future;
                  }
                  return {
                    'outputPath': (call.arguments as Map)['outputPath'],
                    'committed': true,
                  };
                }
                return null;
              });
          old = mode == 'merge' ? f.state.mergeClips() : f.state.exportClips();
          await entered.future.timeout(const Duration(seconds: 3));
          await f.state.createNewProject();
          await waitFor(() => f.state.hasUncertainExport, 'uncertain status');
          if (f.state.uncertainExportDiagnostic == null) {
            errors.add('missing uncertain diagnostic');
          }
          await f.state.openProject('A');
          if (!f.state.hasUncertainExport) {
            errors.add('uncertain lost after project round trip');
          }
          await f.state.mergeClips();
          if (calls != 1) errors.add('new export launched before status check');
          final ok = await f.state.checkUncertainExport(stopFirst: stopFirst);
          await Future<void>.delayed(Duration.zero);
          final expected = status == 'cleaned'
              ? TaskStopStatus.stopped
              : status == 'running'
              ? TaskStopStatus.running
              : TaskStopStatus.unknown;
          if (ok != expected) {
            errors.add('status result expected $expected got $ok');
          }
          if (status == 'cleaned') {
            await waitFor(() => !f.state.hasUncertainExport, 'clear uncertain');
            await f.state.mergeClips();
            if (calls != 2) {
              errors.add('confirmed cleaned did not admit export');
            }
          } else {
            if (!f.state.hasUncertainExport) {
              errors.add('unconfirmed status unlocked gate');
            }
            if ((status == 'unknown' || status == 'failure') &&
                f.state.uncertainExportDiagnostic == null) {
              errors.add('missing query failure diagnostic');
            }
            await f.state.mergeClips();
            if (calls != 1) errors.add('unconfirmed status admitted export');
            cleanupOverride = true;
            await f.state.checkUncertainExport();
            await waitFor(() => !f.state.hasUncertainExport, 'cleanup gate');
          }
          oldResult.completeError(PlatformException(code: 'EXPORT_CANCELLED'));
          await old.timeout(const Duration(seconds: 5));
          await f.state.pendingProjectWrites;
        } catch (e, st) {
          errors.add('HARNESS $e\n$st');
        } finally {
          if (!oldResult.isCompleted) {
            oldResult.completeError(
              PlatformException(code: 'EXPORT_CANCELLED'),
            );
          }
          try {
            if (old != null) await old.timeout(const Duration(seconds: 4));
          } catch (e) {
            errors.add('HARNESS drain $e');
          }
          if (init) {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null);
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(
                  pathChannel,
                  (_) async => f.root.path,
                );
            try {
              await f.close();
            } catch (e) {
              errors.add('HARNESS close $e');
            }
          }
        }
        outcomes.add({
          'seed': seed,
          'status': status,
          'mode': mode,
          'stopFirst': stopFirst,
          'calls': calls,
          'queries': queries,
          'errors': errors,
        });
      }
      final failures = outcomes
          .where((x) => (x['errors'] as List).isNotEmpty)
          .toList();
      final path = Platform.environment['P6_UNCERTAIN_RESULTS'];
      if (path != null) {
        await File(path).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'base': 'current checkout',
            'outcomes': outcomes,
            'failures': failures,
          }),
        );
      }
      print('UNCERTAIN_SUMMARY count=$count failures=${failures.length}');
      if (failures.isNotEmpty) {
        print(
          'FAILING_SEEDS ${failures.map((failure) => failure['seed']).join(',')}\nFIRST ${jsonEncode(failures.first)}',
        );
      }
      expect(failures.length, 0);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
  test(
    'saved merge remains successful when release acknowledgment delays',
    () async {
      final count = regressionSeedCount('P6_RELEASE_COUNT');
      final outcomes = <Map<String, Object?>>[];
      for (var seed = 0; seed < count; seed++) {
        final rng = Random(seed + 120000),
            kind = ['immediate', 'delayed', 'timeout', 'never'][rng.nextInt(4)];
        final f = MobileVideoFixture(), reply = Completer<void>();
        final errors = <String>[];
        var init = false, calls = 0;
        String? reportedError, reportedProgress;
        int? recordedExportMs;
        bool uncertain = false;
        try {
          await f.init(
            exportEngine: NativeMediaExportEngine(
              drainTimeout: const Duration(milliseconds: 20),
            ),
            exportDrainTimeout: const Duration(milliseconds: 20),
          );
          init = true;
          final video = await f.file('original.mp4', 'original');
          f.state.project = f.project(video.path);
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
                  await p.writeAsString('fake-committed-video');
                  return {
                    'outputPath': p.path,
                    'committed': true,
                    'mergedOverlapCount': 1,
                  };
                }
                if (call.method == 'releaseMergeExport') {
                  if (kind == 'immediate') return null;
                  if (kind == 'delayed') {
                    await Future<void>.delayed(const Duration(milliseconds: 3));
                    return null;
                  }
                  if (kind == 'timeout') {
                    await Future<void>.delayed(
                      const Duration(milliseconds: 35),
                    );
                    return null;
                  }
                  await reply.future;
                  return null;
                }
                return null;
              });
          await f.state.mergeClips().timeout(const Duration(seconds: 3));
          reportedError = f.state.errorMessage;
          reportedProgress = f.state.progressMessage;
          recordedExportMs = f.state.project.lastExportDurationMs;
          uncertain = f.state.hasUncertainExport;
          if (calls != 1 || f.state.exportedPaths.length != 1) {
            errors.add('committed output not preserved');
          } else if (!await File(f.state.exportedPaths.single).exists()) {
            errors.add('committed file missing');
          }
          if (f.state.exportCancelled) {
            errors.add('committed export marked cancelled');
          }
          if (!f.state.progressMessage.contains('完成')) {
            errors.add('success progress replaced: ${f.state.progressMessage}');
          }
          if (f.state.errorMessage?.contains('导出失败') == true) {
            errors.add('success reported as export failure');
          }
          if (kind == 'timeout' || kind == 'never') {
            if (!f.state.hasUncertainExport) {
              errors.add('missing uncertain release status');
            }
            if (await f.state.checkUncertainExport() !=
                TaskStopStatus.stopped) {
              errors.add('confirmed cleanup did not clear gate');
            }
            await waitFor(
              () => !f.state.hasUncertainExport,
              'release gate cleanup',
            );
          }
          if (!reply.isCompleted) reply.complete();
          if (kind == 'timeout') {
            await Future<void>.delayed(const Duration(milliseconds: 18));
          }
        } catch (e, st) {
          errors.add('HARNESS $e\n$st');
        } finally {
          if (!reply.isCompleted) reply.complete();
          if (init) {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null);
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(
                  pathChannel,
                  (_) async => f.root.path,
                );
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
          'errorMessage': reportedError,
          'progressMessage': reportedProgress,
          'lastExportDurationMs': recordedExportMs,
          'uncertain': uncertain,
          'errors': errors,
        });
      }
      final failures = outcomes
          .where((x) => (x['errors'] as List).isNotEmpty)
          .toList();
      final path = Platform.environment['P6_RELEASE_RESULTS'];
      if (path != null) {
        await File(path).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'base': 'current checkout',
            'outcomes': outcomes,
            'failures': failures,
          }),
        );
      }
      print('RELEASE_SUMMARY count=$count failures=${failures.length}');
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
