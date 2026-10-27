// ignore_for_file: curly_braces_in_flow_control_structures, unnecessary_underscores

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/diagnostics/mobile_diagnostics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/mobile_video_fixture.dart';
import 'seed_count.dart';

class LogBackend implements DiagnosticBackend {
  final messages = <String>[];
  @override
  Future<void> initialize(String v, String l) async {}
  @override
  Future<void> append(String m, String? k) async {
    messages.add(m);
  }

  @override
  Future<DiagnosticSnapshot> snapshot() async =>
      DiagnosticSnapshot(lines: messages, available: true);
}

class EmptyEngine extends MobileAnalysisEngineUnavailable {
  int calls = 0;
  @override
  Stream<AnalysisProgress> analyze({
    required VideoInfo video,
    required Roi hoopRoi,
    Roi? rimRoi,
    required Roi netRoi,
    required AnalysisSettings settings,
  }) async* {
    calls++;
    yield const AnalysisProgress(
      stage: AnalysisStage.completed,
      progress: 1,
      message: 'done',
    );
  }
}

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

ProjectSnapshot persisted(ProjectSnapshot value) => const ProjectPackageCodec()
    .decode(const ProjectPackageCodec().encode(value));
Future<ProjectSnapshot> load(MobileVideoFixture f, String id) async =>
    const ProjectPackageCodec().decode(
      await File('${f.data.path}/projects/$id.json').readAsString(),
    );
void equalProject(
  ProjectSnapshot actual,
  ProjectSnapshot expected,
  String message,
) {
  check(
    jsonEncode(persisted(actual).toJson()) ==
        jsonEncode(persisted(expected).toJson()),
    '$message actual=${jsonEncode(actual.toJson())} expected=${jsonEncode(expected.toJson())}',
  );
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'seeded pending writes across project transitions and analysis',
    () async {
      final old = MobileDiagnostics.instance,
          failures = <Map<String, Object?>>[],
          coverage = <String, int>{},
          matrix = <String, int>{};
      final seedStart =
          int.tryParse(Platform.environment['BHE_BARRIER_SEED'] ?? '') ?? 10000;
      final total = regressionSeedCount('BHE_BARRIER_COUNT');
      for (var seed = seedStart; seed < seedStart + total; seed++) {
        final rng = Random(seed),
            f = MobileVideoFixture(),
            engine = EmptyEngine(),
            backend = LogBackend();
        MobileDiagnostics.instance = MobileDiagnostics(backend);
        final transition = [
          'open',
          'new',
          'import',
          'delete',
          'analysis',
        ][rng.nextInt(5)];
        final first = ['review', 'rename', 'add'][rng.nextInt(3)];
        final second = rng.nextBool()
            ? ['review', 'rename', 'add'][rng.nextInt(3)]
            : null;
        final fail = rng.nextBool();
        final delayMs = rng.nextInt(4);
        final scenario =
            'seed=$seed first=$first second=$second transition=$transition fail=$fail delay_ms=$delayMs';
        coverage[transition] = (coverage[transition] ?? 0) + 1;
        matrix['$transition/$first/${fail ? 'fail' : 'ok'}'] =
            (matrix['$transition/$first/${fail ? 'fail' : 'ok'}'] ?? 0) + 1;
        var initialized = false;
        Completer<void>? blocked;
        try {
          await f.init(engine: engine);
          initialized = true;
          final video = await f.file('original.mp4', 'original');
          final a = f.project(video.path),
              b = f.project(video.path, id: 'B').copyWith(clearVideo: true);
          f.state.project = a;
          f.state.recentProjects = [a, b];
          await f.file(
            'BHE Mobile/projects/B.json',
            const ProjectPackageCodec().encode(b),
          );
          check(await f.state.renameProject('Baseline'), 'baseline failed');
          final baseline = f.state.project;
          if (transition == 'import') {
            final incoming = f
                .project(video.path, id: 'C')
                .copyWith(clearVideo: true, name: 'Imported');
            f.choose(
              await f.file(
                'import.json',
                const ProjectPackageCodec().encode(incoming),
              ),
            );
          }
          final entered = Completer<void>(), release = Completer<void>();
          blocked = release;
          var firstCall = true;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                (_) async {
                  if (firstCall) {
                    firstCall = false;
                    entered.complete();
                    await release.future;
                    if (fail) throw PlatformException(code: 'barrier_injected');
                  }
                  return f.root.path;
                },
              );
          Future<bool> submit(String op, String token) => switch (op) {
            'review' => f.state.updateCandidateNote('goal', token),
            'rename' => f.state.renameProject(token),
            _ => f.state.addPlayer(token),
          };
          ProjectSnapshot apply(ProjectSnapshot p, String op, String token) =>
              switch (op) {
                'review' => p.copyWith(
                  candidates: [
                    for (final c in p.candidates)
                      if (c.id == 'goal') c.copyWith(note: token) else c,
                  ],
                ),
                'rename' => p.copyWith(name: token),
                _ => p.copyWith(players: [...p.players, token]),
              };
          final one = submit(first, 'first_$seed');
          await entered.future.timeout(const Duration(seconds: 5));
          final two = second == null ? null : submit(second, 'second_$seed');
          var transitionFinished = false;
          final action = switch (transition) {
            'open' => f.state.openProject('B'),
            'new' => f.state.createNewProject(),
            'import' => f.state.importProject(),
            'delete' => f.state.clearProject(),
            _ => f.state.startAnalysis(),
          };
          unawaited(
            action.then(
              (_) => transitionFinished = true,
              onError: (Object _, StackTrace __) {},
            ),
          );
          await Future<void>.delayed(Duration(milliseconds: delayMs));
          if (transition == 'import') {
            for (
              var i = 0;
              i < 300 && !f.state.projectTransitioning && !transitionFinished;
              i++
            ) {
              await Future<void>.delayed(const Duration(milliseconds: 1));
            }
            check(
              f.state.projectTransitioning,
              'import did not enter its commit barrier',
            );
          }
          check(
            !transitionFinished,
            'transition completed while first write paused',
          );
          if (transition != 'analysis') {
            check(
              !await f.state
                  .updateCandidateNote('goal', 'late_$seed')
                  .timeout(const Duration(seconds: 2)),
              'late review accepted while switching',
            );
            check(
              !await f.state
                  .renameProject('late_$seed')
                  .timeout(const Duration(seconds: 2)),
              'late rename accepted while switching',
            );
            check(
              !await f.state
                  .addPlayer('late_$seed')
                  .timeout(const Duration(seconds: 2)),
              'late add accepted while switching',
            );
          } else {
            check(
              engine.calls == 0,
              'analysis started before prior write completed',
            );
          }
          release.complete();
          check(
            await one == !fail,
            'first result disagrees with injected failure',
          );
          if (two != null) check(await two, 'queued second mutation failed');
          await action.timeout(const Duration(seconds: 10));
          await f.state.pendingProjectWrites;
          var expected = baseline;
          if (!fail) expected = apply(expected, first, 'first_$seed');
          if (second != null)
            expected = apply(expected, second, 'second_$seed');
          if (fail) {
            await Future<void>.delayed(Duration.zero);
            check(
              backend.messages.any((m) => m.startsWith('app error:')),
              'failed write missing diagnostics',
            );
          }
          final aFile = File('${f.data.path}/projects/A.json');
          if (transition == 'delete') {
            check(!await aFile.exists(), 'deleted A project reappeared');
            check(f.state.project.id == 'B', 'delete did not select B');
          } else if (transition == 'analysis') {
            expected = expected.copyWith(candidates: const []);
            check(engine.calls == 1, 'analysis never completed');
            check(f.state.project.id == 'A', 'analysis changed project');
            final disk = await load(f, 'A');
            check(
              jsonEncode(disk.players) == jsonEncode(expected.players) &&
                  disk.name == expected.name &&
                  disk.candidates.isEmpty,
              'analysis lost prior name/player or did not clear candidates',
            );
            equalProject(disk, f.state.project, 'analysis disk/memory');
          } else {
            equalProject(
              await load(f, 'A'),
              expected,
              'previous project disk/model',
            );
            switch (transition) {
              case 'open':
                check(f.state.project.id == 'B', 'open selected wrong project');
                equalProject(f.state.project, b, 'opened project/model');
              case 'new':
                check(
                  f.state.project.id != 'A' &&
                      f.state.project.video == null &&
                      f.state.project.candidates.isEmpty,
                  'new project state',
                );
              case 'import':
                check(
                  f.state.project.id == 'C' &&
                      f.state.project.name == 'Imported',
                  'import selected wrong project',
                );
            }
          }
          check(
            !f.state.canUndoReview,
            'transition/analysis retained stale undo',
          );
          final index = jsonDecode(
            await File('${f.data.path}/project_index.json').readAsString(),
          );
          check(
            jsonEncode(index) ==
                jsonEncode(f.state.recentProjects.map((p) => p.id).toList()),
            'index/recent mismatch',
          );
          if (transition == 'open' ||
              transition == 'import' ||
              transition == 'delete') {
            final disk = await load(f, f.state.project.id);
            equalProject(disk, f.state.project, 'active project disk/memory');
          }
        } catch (error, stack) {
          if (blocked != null && !blocked.isCompleted) blocked.complete();
          failures.add({
            'seed': seed,
            'scenario': scenario,
            'minimal_reproduction': [
              'pause first $first write${fail ? ' and inject failure' : ''}',
              if (second != null) 'queue $second write',
              'start $transition while write is paused',
              if (transition != 'analysis') 'attempt late review, rename, add',
              'release, drain, check project and index',
            ],
            'error': '$error',
            'stack': '$stack',
          });
        } finally {
          if (initialized) {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(
                  const MethodChannel('plugins.flutter.io/path_provider'),
                  (_) async => f.root.path,
                );
            await f.close();
          }
        }
      }
      final result = {
        'base': Platform.environment['BHE_TEST_BASE'] ?? 'workspace',
        'seed_start': seedStart,
        'sequences': total,
        'coverage': coverage,
        'matrix': matrix,
        'failure_count': failures.length,
        'failures': failures,
      };
      final file = Platform.environment['BHE_BARRIER_RESULT'];
      if (file != null)
        await File(
          file,
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
      debugPrint(
        'BARRIER_SUMMARY ${jsonEncode({'sequences': total, 'coverage': coverage, 'failures': failures.length})}',
      );
      if (failures.isNotEmpty)
        debugPrint(
          'FAILING_SEEDS ${failures.map((failure) => failure['seed']).join(',')}\nFIRST_FAILURE ${jsonEncode(failures.first)}',
        );
      MobileDiagnostics.instance = old;
      expect(
        failures,
        isEmpty,
        reason: 'See BHE_BARRIER_RESULT for scenario and reproducible seed',
      );
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
