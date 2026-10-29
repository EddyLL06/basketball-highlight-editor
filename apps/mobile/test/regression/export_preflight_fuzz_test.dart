// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/mobile_video_fixture.dart';
import 'seed_count.dart';

Future<void> until(bool Function() ok, String what) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException(what);
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'export admission controlled interleavings',
    () async {
      final outcomes = <Map<String, Object?>>[];
      const media = MethodChannel('com.bhe.bhe/mobile_media'),
          paths = MethodChannel('plugins.flutter.io/path_provider');
      final count = regressionSeedCount('P6_COUNT');
      for (var seed = 0; seed < count; seed++) {
        final random = Random(seed + 30000),
            phase = [
              'validation',
              'prepare',
              'native',
              'commit',
            ][random.nextInt(4)],
            action = [
              'again_merge',
              'again_separate',
              'cancel',
              'switch',
            ][random.nextInt(4)];
        final mode = phase == 'commit' || random.nextBool()
                ? 'merge'
                : 'separate',
            validationFails = phase == 'validation' && random.nextInt(3) == 0;
        final f = MobileVideoFixture(),
            entered = Completer<void>(),
            release = Completer<void>(),
            nativeResult = Completer<Object?>();
        final problems = <String>[],
            cancelIds = <String?>[],
            ids = <String>[],
            outputPaths = <String>[];
        var earlyRetry = false;
        var initialized = false,
            armed = false,
            active = 0,
            maxActive = 0,
            nativeCalls = 0,
            probeCalls = 0,
            oldStarted = false;
        Future<void>? old, switching;
        try {
          await f.init(
            probe: (file) async {
              probeCalls++;
              if (phase == 'validation' && armed && probeCalls == 1) {
                entered.complete();
                await release.future;
                if (validationFails) {
                  throw StateError('injected video validation failure');
                }
              }
              return MobileVideoFixture.inspect(file);
            },
          );
          initialized = true;
          final file = await f.file('original.mp4', 'original');
          f.state.project = f.project(file.path);
          armed = true;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(paths, (_) async {
                if (!entered.isCompleted &&
                    (phase == 'prepare' ||
                        (phase == 'commit' &&
                            f.state.exportedPaths.isNotEmpty))) {
                  entered.complete();
                  await release.future;
                }
                return f.root.path;
              });
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(media, (call) async {
                if (call.method == 'registerMergeExport') {
                  ids.add((call.arguments as Map)['exportId'] as String);
                  return true;
                }
                if (call.method == 'cancelExport') {
                  cancelIds.add(
                    (call.arguments as Map?)?['exportId'] as String?,
                  );
                  return null;
                }
                if (call.method == 'mergeClips' ||
                    call.method == 'exportClip') {
                  final arguments = call.arguments as Map;
                  nativeCalls++;
                  active++;
                  maxActive = max(maxActive, active);
                  outputPaths.add(arguments['outputPath'] as String);
                  if (phase == 'native' && !oldStarted) {
                    oldStarted = true;
                    entered.complete();
                    try {
                      return await nativeResult.future;
                    } finally {
                      active--;
                    }
                  }
                  active--;
                  return {
                    'outputPath': arguments['outputPath'],
                    'committed': true,
                    'mergedOverlapCount': 1,
                  };
                }
                return null;
              });
          old = mode == 'merge' ? f.state.mergeClips() : f.state.exportClips();
          await entered.future.timeout(const Duration(seconds: 5));
          if (!f.state.exporting) {
            problems.add('exporting false during admitted task');
          }
          if (action == 'again_merge') await f.state.mergeClips();
          if (action == 'again_separate') await f.state.exportClips();
          if ((action == 'again_merge' || action == 'again_separate') &&
              nativeCalls > (phase == 'native' || phase == 'commit' ? 1 : 0)) {
            problems.add('second click launched native');
          }
          if (action == 'cancel') {
            await f.state.cancelExport();
            if (phase == 'validation' || phase == 'prepare') {
              final before = nativeCalls;
              await f.state.mergeClips().timeout(const Duration(seconds: 10));
              if (nativeCalls != before + 1) {
                problems.add('immediate retry did not launch');
              }
              earlyRetry = true;
            }
          }
          if (action == 'switch') {
            switching = f.state.createNewProject();
            await until(() => f.state.projectTransitioning, 'switch barrier');
          }
          if (phase == 'native') {
            if (action == 'cancel' || action == 'switch') {
              nativeResult.completeError(
                PlatformException(code: 'EXPORT_CANCELLED'),
              );
            } else {
              nativeResult.complete({
                'outputPath': outputPaths.first,
                'committed': true,
                'mergedOverlapCount': 1,
              });
            }
          } else {
            release.complete();
          }
          await old.timeout(const Duration(seconds: 10));
          if (switching != null) {
            await switching.timeout(const Duration(seconds: 10));
          }
          await f.state.pendingProjectWrites.timeout(
            const Duration(seconds: 10),
          );
          if (maxActive > 1) problems.add('native overlap max=$maxActive');
          if (f.state.exporting) problems.add('exporting stuck true');
          if (action == 'switch' && f.state.project.id == 'A') {
            problems.add('switch did not complete');
          }
          if (action == 'switch' && f.state.exportedPaths.isNotEmpty) {
            problems.add('old result affected new project');
          }
          if (mode == 'merge' &&
              phase == 'native' &&
              action == 'cancel' &&
              ids.isNotEmpty &&
              cancelIds.any((id) => id != ids.first)) {
            problems.add('cancel targets wrong id');
          }
          if (phase == 'commit' &&
              action == 'cancel' &&
              (f.state.exportCancelled || f.state.exportedPaths.isEmpty)) {
            problems.add('post-commit cancel lost success');
          }
          final beforeRetry = nativeCalls;
          if (action != 'switch' &&
              !earlyRetry &&
              (validationFails || action == 'cancel')) {
            await f.state.mergeClips().timeout(const Duration(seconds: 10));
            if (nativeCalls != beforeRetry + 1) {
              problems.add('retry did not launch');
            }
          }
          if (active != 0) problems.add('native task still active');
        } catch (e, st) {
          problems.add('HARNESS $e\n$st');
        } finally {
          if (!release.isCompleted) release.complete();
          if (!nativeResult.isCompleted) {
            nativeResult.complete({
              'outputPath': 'ignored.mp4',
              'committed': true,
            });
          }
          try {
            if (old != null) await old.timeout(const Duration(seconds: 5));
            if (switching != null) {
              await switching.timeout(const Duration(seconds: 5));
            }
          } catch (e) {
            problems.add('HARNESS drain $e');
          }
          if (initialized) {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(media, null);
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(paths, (_) async => f.root.path);
            try {
              await f.close();
            } catch (e) {
              problems.add('HARNESS close $e');
            }
          }
        }
        outcomes.add({
          'seed': seed,
          'phase': phase,
          'action': action,
          'mode': mode,
          'validationFails': validationFails,
          'earlyRetry': earlyRetry,
          'nativeCalls': nativeCalls,
          'maxActive': maxActive,
          'cancelIds': cancelIds,
          'ids': ids,
          'outputPaths': outputPaths,
          'errors': problems,
        });
      }
      final failures = outcomes
          .where((o) => (o['errors'] as List).isNotEmpty)
          .toList();
      final result = {
        'commit': 'e3fd558',
        'outcomes': outcomes,
        'failures': failures,
      };
      final path = Platform.environment['P6_RESULTS'];
      if (path != null) {
        await File(
          path,
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
      }
      print('EXPORT_SUMMARY count=$count failures=${failures.length}');
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
