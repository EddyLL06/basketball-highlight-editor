import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_app_state.dart';
import 'package:bhe_mobile/features/diagnostics/mobile_diagnostics.dart'
    as diag;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/mobile_video_fixture.dart';
import 'seed_count.dart';

class Engine extends MobileAnalysisEngineUnavailable {
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
      candidates: [],
    );
  }
}

class Sink implements diag.DiagnosticBackend {
  final lines = <String>[];
  @override
  Future<void> initialize(String version, String language) async {}
  @override
  Future<void> append(String message, String? key) async {
    lines.add(message);
  }

  @override
  Future<diag.DiagnosticSnapshot> snapshot() async =>
      diag.DiagnosticSnapshot(lines: lines, available: true);
}

Future<void> until(bool Function() condition, String label) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException(label);
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

ProjectSnapshot normalized(ProjectSnapshot p) =>
    const ProjectPackageCodec().decode(const ProjectPackageCodec().encode(p));
Map<String, Object?> snapshot(MobileAppState s) => {
  'players': List<String>.of(s.project.players),
  'candidates': [for (final c in normalized(s.project).candidates) c.toJson()],
  'undo': s.canUndoReview,
  'undoEntries': [
    for (final e in s.reviewHistory.allEntries)
      {
        'kind': e.kind.name,
        'focus': e.focusId,
        'beforeNote': e.before[e.focusId]?.note,
      },
  ],
};
Future<ProjectSnapshot> disk(MobileVideoFixture f) async =>
    const ProjectPackageCodec().decode(
      await File('${f.data.path}/projects/A.json').readAsString(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'pending analysis initialization write preserves review until engine starts',
    () async {
      final start =
          int.tryParse(Platform.environment['P2A_COMMIT_START'] ?? '') ?? 0;
      final count = regressionSeedCount('P2A_COMMIT_COUNT');
      final oldDiag = diag.MobileDiagnostics.instance,
          outcomes = <Map<String, Object?>>[];
      for (var seed = start; seed < start + count; seed++) {
        final random = Random(seed + 92000),
            f = MobileVideoFixture(),
            engine = Engine(),
            sink = Sink();
        final action = [
          'cancel',
          'switch',
          'replace',
          'recreate',
          'members',
          'valid',
        ][random.nextInt(6)];
        final fail = random.nextBool();
        final errors = <String>[];
        final events = <Map<String, Object?>>[];
        Map<String, Object?> observed = {};
        var initialized = false;
        Completer<void>? release, pickerRelease;
        Future<void>? analysis, pending;
        Future<bool>? recreate;
        diag.MobileDiagnostics.instance = diag.MobileDiagnostics(sink);
        try {
          await f.init(engine: engine);
          initialized = true;
          final source = await f.file('original.mp4', 'original');
          f.state.project = f.project(source.path).copyWith(players: []);
          f.state.playerGroups = [
            (name: 'Team', players: ['Bob']),
          ];
          f.state.rosterSelection.choose('Team', ['Bob']);
          if (!await f.state.updateCandidateNote('goal', 'reviewed note')) {
            throw StateError('baseline review failed');
          }
          if (!f.state.canUndoReview) throw StateError('baseline undo missing');
          final baseline = snapshot(f.state),
              oldCandidate = (baseline['candidates'] as List).single;
          f.state.addListener(() {
            if (f.state.project.id == 'A') {
              events.add({
                ...snapshot(f.state),
                'engine': engine.calls,
                'analysing': f.state.analysing,
                'video': f.state.project.video?.name,
              });
            }
          });
          final pickerEntered = Completer<void>();
          if (action == 'replace') {
            final replacement = await f.file('replacement.mp4', 'replacement');
            f.choose(replacement);
            final pick = f.picker.pick!;
            pickerRelease = Completer<void>();
            f.picker.pick = () async {
              pickerEntered.complete();
              await pickerRelease!.future;
              return pick();
            };
          }
          final entered = Completer<void>();
          release = Completer<void>();
          var first = true;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                (_) async {
                  if (first) {
                    first = false;
                    entered.complete();
                    await release!.future;
                    if (fail) {
                      throw PlatformException(
                        code: 'injected_analysis_commit_failure',
                      );
                    }
                  }
                  return f.root.path;
                },
              );
          final beforeQueue = f.state.pendingProjectWrites;
          analysis = f.state.startAnalysis(
            rosterPlayers: ['Bob'],
            expectedRosterGroup: 'Team',
            expectedProjectId: f.state.project.id,
            expectedSession: f.state.projectSession,
            expectedVideoGeneration: f.state.videoPreparationGeneration,
          );
          await entered.future.timeout(const Duration(seconds: 5));
          if (identical(beforeQueue, f.state.pendingProjectWrites)) {
            throw StateError('analysis transaction did not enter write');
          }
          switch (action) {
            case 'cancel':
              pending = f.state.cancelAnalysis();
              await until(() => !f.state.analysing, 'cancel intent');
            case 'switch':
              pending = f.state.createNewProject();
              await until(() => f.state.projectTransitioning, 'switch barrier');
            case 'replace':
              pending = f.state.pickVideo();
              await until(() => !f.state.analysing, 'replacement cancellation');
            case 'recreate':
              if (!await f.state.deletePlayerGroup('Team')) {
                throw StateError('delete failed');
              }
              recreate = f.state.savePlayerGroup('Team');
            case 'members':
              if (!await f.state.editPlayerGroup('Team', 'Team', ['Carol'])) {
                throw StateError('edit failed');
              }
            case 'valid':
              break;
          }
          release.complete();
          await analysis.timeout(const Duration(seconds: 10));
          if (action == 'replace') {
            await pickerEntered.future.timeout(const Duration(seconds: 10));
          } else if (pending != null) {
            await pending.timeout(const Duration(seconds: 10));
          }
          if (recreate != null &&
              !await recreate.timeout(const Duration(seconds: 10))) {
            throw StateError('recreate failed');
          }
          await f.state.pendingProjectWrites.timeout(
            const Duration(seconds: 10),
          );
          final saved = await disk(f);
          final oldLive = action == 'switch' ? events.last : snapshot(f.state);
          final savedCandidate = [for (final c in saved.candidates) c.toJson()];
          observed = {
            'old_live': oldLive,
            'disk_players': saved.players,
            'disk_candidates': savedCandidate,
            'engine': engine.calls,
            'first_write_failed': fail,
            'active_project': f.state.project.id,
          };
          void check(bool ok, String m) {
            if (!ok) errors.add(m);
          }

          check(
            jsonEncode(saved.players) == jsonEncode(oldLive['players']),
            'disk/live players differ',
          );
          check(
            saved.players.isEmpty ||
                jsonEncode(saved.players) == jsonEncode(['Bob']),
            'unexpected player mutation',
          );
          if (engine.calls == 0) {
            check(
              jsonEncode(oldLive['candidates']) == jsonEncode([oldCandidate]),
              'old live candidate and review lost',
            );
            check(
              jsonEncode(savedCandidate) == jsonEncode([oldCandidate]),
              'disk candidate and review lost',
            );
            check(oldLive['undo'] == true, 'old undo missing');
            check(
              jsonEncode(oldLive['undoEntries']) ==
                  jsonEncode(baseline['undoEntries']),
              'old undo entry mismatch',
            );
          }
          if (action == 'cancel' ||
              action == 'switch' ||
              action == 'replace' ||
              fail) {
            check(
              engine.calls == 0,
              'engine started after cancelled/failed initialization',
            );
          }
          if (fail) {
            check(
              sink.lines.any((line) => line.contains('app error: analysis')),
              'write failure diagnostic missing',
            );
          }
          if (action == 'switch') {
            check(f.state.project.id != 'A', 'switch did not complete');
          }
          if (action == 'replace') {
            pickerRelease!.complete();
            await pending!.timeout(const Duration(seconds: 10));
            await f.state.pendingProjectWrites.timeout(
              const Duration(seconds: 10),
            );
            check(
              f.state.project.video?.name == 'replacement.mp4',
              'replacement did not complete',
            );
          }
        } catch (e, st) {
          errors.add('HARNESS $e\n$st');
        } finally {
          if (release != null && !release.isCompleted) release.complete();
          if (pickerRelease != null && !pickerRelease.isCompleted) {
            pickerRelease.complete();
          }
          try {
            if (analysis != null) {
              await analysis.timeout(const Duration(seconds: 10));
            }
            if (pending != null) {
              await pending.timeout(const Duration(seconds: 10));
            }
            if (recreate != null) {
              await recreate.timeout(const Duration(seconds: 10));
            }
            if (initialized) {
              await f.state.pendingProjectWrites.timeout(
                const Duration(seconds: 10),
              );
            }
          } catch (e) {
            errors.add('HARNESS cleanup $e');
          }
          if (initialized) {
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(
                  const MethodChannel('plugins.flutter.io/path_provider'),
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
          'action': action,
          'write_fails': fail,
          'observed': observed,
          'errors': errors,
        });
      }
      diag.MobileDiagnostics.instance = oldDiag;
      final failures = outcomes
          .where((x) => (x['errors'] as List).isNotEmpty)
          .toList();
      final result = {
        'base': 'current checkout',
        'seed_start': start,
        'count': count,
        'failures': failures,
        'outcomes': outcomes,
      };
      final file = Platform.environment['P2A_COMMIT_RESULT'];
      if (file != null) {
        await File(
          file,
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
      }
      debugPrint('COMMIT_SUMMARY seeds=$count failures=${failures.length}');
      for (final action in [
        'cancel',
        'switch',
        'replace',
        'recreate',
        'members',
        'valid',
      ]) {
        final items = outcomes.where((x) => x['action'] == action).toList();
        debugPrint(
          'ACTION $action count=${items.length} failures=${items.where((x) => (x['errors'] as List).isNotEmpty).length}',
        );
      }
      if (failures.isNotEmpty) {
        debugPrint(
          'FAILING_SEEDS ${failures.map((failure) => failure['seed']).join(',')}\nFIRST_FAILURE ${jsonEncode(failures.first)}',
        );
      }
      expect(failures.length, 0, reason: 'see P2A_COMMIT_RESULT');
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
