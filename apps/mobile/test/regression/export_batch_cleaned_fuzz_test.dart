// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:bhe_core/bhe_core.dart';
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
  test(
    'stale status, frozen batch, and delayed replies under interleaving',
    () async {
      final total = regressionSeedCount('P6_BATCH_COUNT'),
          start =
              int.tryParse(Platform.environment['P6_BATCH_START'] ?? '') ?? 0;
      final outcomes = <Map<String, Object?>>[];
      const channel = MethodChannel('com.bhe.bhe/mobile_media'),
          paths = MethodChannel('plugins.flutter.io/path_provider');
      for (var seed = start; seed < start + total; seed++) {
        final rng = Random(seed + 150000),
            early = rng.nextBool(),
            answer = ['cleaned', 'running', 'unknown'][rng.nextInt(3)],
            switchProject = rng.nextBool(),
            mode = rng.nextBool() ? 'merge' : 'separate',
            stopFirst = rng.nextBool(),
            third = rng.nextBool();
        final f = MobileVideoFixture(),
            oldEntered = Completer<void>(),
            oldResult = Completer<Object?>(),
            queryEntered = Completer<void>(),
            queryResult = Completer<Object?>(),
            nextEntered = Completer<void>(),
            nextResult = Completer<Object?>();
        final errors = <String>[], trace = <String>[];
        var init = false,
            oldCalls = 0,
            nextCalls = 0,
            otherCalls = 0,
            active = 0,
            maxActive = 0,
            queryCompleted = false,
            oldRegistryActive = false;
        Future<void>? old, next, additional;
        Future<TaskStopStatus>? query;
        TaskStopStatus? observed;
        try {
          await f.init();
          init = true;
          final file = await f.file('original.mp4', 'original');
          f.state.project = f.project(file.path);
          if (!await f.state.renameProject('Baseline')) {
            throw StateError('baseline failed');
          }
          final video = f.state.project.video!,
              engine1 = NativeMediaExportEngine(
                drainTimeout: const Duration(milliseconds: 300),
              ),
              engine2 = NativeMediaExportEngine(
                drainTimeout: const Duration(milliseconds: 300),
              ),
              engine3 = NativeMediaExportEngine(
                drainTimeout: const Duration(milliseconds: 300),
              );
          const a = Candidate(
                id: 'old-A',
                startMs: 0,
                endMs: 1000,
                eventMs: 500,
              ),
              b = Candidate(
                id: 'old-B',
                startMs: 2000,
                endMs: 3000,
                eventMs: 2500,
              ),
              n = Candidate(
                id: 'new-N',
                startMs: 4000,
                endMs: 5000,
                eventMs: 4500,
              );
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, (call) async {
                if (call.method == 'registerMergeExport') return true;
                if (call.method == 'isExportActive') {
                  if (!queryEntered.isCompleted) queryEntered.complete();
                  return queryResult.future;
                }
                if (call.method == 'exportClip') {
                  final id = (call.arguments as Map)['exportId'];
                  if (id == 'old-A') {
                    oldCalls++;
                    oldRegistryActive = true;
                    active++;
                    maxActive = max(maxActive, active);
                    oldEntered.complete();
                    try {
                      return await oldResult.future;
                    } finally {
                      oldRegistryActive = false;
                      active--;
                    }
                  }
                  if (id == 'old-B') {
                    oldCalls++;
                    return {'outputPath': 'forbidden-B.mp4'};
                  }
                  if (id == 'new-N') {
                    if (oldRegistryActive) {
                      errors.add('new export before registry cleaned');
                    }
                    nextCalls++;
                    active++;
                    maxActive = max(maxActive, active);
                    nextEntered.complete();
                    try {
                      return await nextResult.future;
                    } finally {
                      active--;
                    }
                  }
                  otherCalls++;
                  return {'outputPath': 'third.mp4'};
                }
                if (call.method == 'mergeClips') {
                  final path = (call.arguments as Map)['outputPath'] as String;
                  if (path == 'next.mp4') {
                    if (oldRegistryActive) {
                      errors.add('new export before registry cleaned');
                    }
                    nextCalls++;
                    active++;
                    maxActive = max(maxActive, active);
                    nextEntered.complete();
                    try {
                      return await nextResult.future;
                    } finally {
                      active--;
                    }
                  }
                  otherCalls++;
                  return {'outputPath': path, 'committed': true};
                }
                return null;
              });
          old = engine1
              .exportClips(
                video: video,
                candidates: [a, b],
                outputDirectory: 'old',
              )
              .toList()
              .then<void>((_) {}, onError: (Object _, StackTrace _) {});
          await oldEntered.future.timeout(const Duration(seconds: 4));
          trace.add('old A started');
          query = engine2.checkPreviousExport(stopFirst: stopFirst);
          await queryEntered.future.timeout(const Duration(seconds: 4));
          trace.add('query A freezes batch');
          if (!early) {
            oldResult.complete({'outputPath': 'old-A.mp4'});
            await old;
            trace.add('A reply before query');
          }
          if (switchProject) {
            await f.state.createNewProject();
            await f.state.openProject('A');
            trace.add('project round trip');
          }
          if (early) {
            if (answer == 'cleaned') oldRegistryActive = false;
            queryResult.complete(
              answer == 'cleaned'
                  ? false
                  : answer == 'running'
                  ? true
                  : null,
            );
            observed = await query;
            queryCompleted = true;
            trace.add('query returns $answer before A reply');
          }
          next =
              (mode == 'merge'
                      ? engine2.mergeClips(
                          video: video,
                          candidates: [n],
                          outputPath: 'next.mp4',
                        )
                      : engine2.exportClips(
                          video: video,
                          candidates: [n],
                          outputDirectory: 'next',
                        ))
                  .toList()
                  .then<void>((_) {}, onError: (Object _, StackTrace _) {});
          if (early) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            if (answer == 'cleaned') {
              if (!nextEntered.isCompleted) {
                errors.add('cleaned registry did not admit new task');
              }
              if (oldRegistryActive) {
                errors.add('registry still active after cleaned');
              }
            } else if (nextEntered.isCompleted) {
              errors.add('new native call before registry cleaned');
            }
            final projectBeforeLate = jsonEncode(f.state.project.toJson());
            if (!oldResult.isCompleted) {
              oldResult.complete({'outputPath': 'old-A.mp4'});
            }
            await old;
            if (jsonEncode(f.state.project.toJson()) != projectBeforeLate) {
              errors.add('late old reply modified current project');
            }
          }
          await nextEntered.future.timeout(const Duration(seconds: 4));
          trace.add('new task native started');
          if (!queryCompleted) {
            queryResult.complete(false);
            observed = await query;
            queryCompleted = true;
            trace.add('stale query returns');
            if (observed != TaskStopStatus.unknown) {
              errors.add('stale query not unknown: $observed');
            }
          }
          if (third) {
            additional = engine3
                .mergeClips(
                  video: video,
                  candidates: [n],
                  outputPath: 'third.mp4',
                )
                .toList()
                .then<void>((_) {}, onError: (Object _, StackTrace _) {});
            await Future<void>.delayed(const Duration(milliseconds: 4));
            if (otherCalls > 0) errors.add('stale query released next owner');
          }
          if (oldCalls != 1) {
            errors.add('frozen old batch launched B: $oldCalls');
          }
          nextResult.complete({'outputPath': 'next.mp4', 'committed': true});
          await next;
          if (additional != null) await additional;
          // Dart replies can overlap after native registry cleanup. The registry
          // check above enforces the physical export admission boundary.
        } catch (e, st) {
          errors.add('HARNESS $e\n$st');
        } finally {
          if (!oldResult.isCompleted) {
            oldResult.complete({'outputPath': 'old-A.mp4'});
          }
          if (!queryResult.isCompleted) queryResult.complete(false);
          if (!nextResult.isCompleted) {
            nextResult.complete({'outputPath': 'next.mp4', 'committed': true});
          }
          try {
            if (old != null) await old.timeout(const Duration(seconds: 4));
            if (query != null) await query.timeout(const Duration(seconds: 4));
            if (next != null) await next.timeout(const Duration(seconds: 4));
            if (additional != null) {
              await additional.timeout(const Duration(seconds: 4));
            }
          } catch (e) {
            errors.add('HARNESS drain $e');
          }
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
          'early': early,
          'answer': answer,
          'mode': mode,
          'stopFirst': stopFirst,
          'switchProject': switchProject,
          'third': third,
          'observed': '$observed',
          'oldCalls': oldCalls,
          'nextCalls': nextCalls,
          'maxActive': maxActive,
          'trace': trace,
          'errors': errors,
        });
      }
      final failures = outcomes
          .where((x) => (x['errors'] as List).isNotEmpty)
          .toList();
      final p = Platform.environment['P6_BATCH_RESULTS'];
      if (p != null) {
        await File(p).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'base': 'current checkout',
            'outcomes': outcomes,
            'failures': failures,
          }),
        );
      }
      print('BATCH_SUMMARY count=$total failures=${failures.length}');
      if (failures.isNotEmpty) {
        print(
          'FAILING_SEEDS ${failures.map((failure) => failure['seed']).join(',')}\nFIRST ${jsonEncode(failures.first)}',
        );
      }
      expect(failures.length, 0);
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
