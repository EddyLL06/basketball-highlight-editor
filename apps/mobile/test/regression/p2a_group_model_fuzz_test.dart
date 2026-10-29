// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/mobile_app_state.dart';
import 'package:bhe_mobile/features/diagnostics/mobile_diagnostics.dart'
    as diaglib;
import 'package:bhe_mobile/features/player_groups/player_group_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import '../support/mobile_video_fixture.dart';
import 'seed_count.dart';

class RecordingAnalysis extends MobileAnalysisEngineUnavailable {
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

const gkey = 'flutter.bhe.player_groups';
const dkey = 'flutter.bhe.default_player_group';
const names = ['Alpha', 'Beta', 'Gamma', 'Delta'];
const players = ['Alice', 'Bob', 'Carol', 'Dan', 'Eve'];

class FaultPrefs extends InMemorySharedPreferencesStore {
  FaultPrefs(super.data) : super.withData();
  String? failKey;
  int failuresLeft = 0;
  int hits = 0;
  int delayHits = 0;
  final failurePlan = <String>[];
  bool delay = false;
  Completer<void>? entered;
  Completer<void>? release;
  Future<void> intercept(String key) async {
    if (entered != null) {
      final e = entered!;
      entered = null;
      e.complete();
      await release!.future;
    } else if (delay) {
      delayHits++;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    if (failurePlan.isNotEmpty && failurePlan.first == key) {
      failurePlan.removeAt(0);
      hits++;
      throw PlatformException(code: 'injected_write_failure', message: key);
    }
    if (key == failKey && failuresLeft > 0) {
      failuresLeft--;
      hits++;
      throw PlatformException(code: 'injected_write_failure', message: key);
    }
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    await intercept(key);
    return super.setValue(type, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    await intercept(key);
    return super.remove(key);
  }
}

class CapturedDiagnostics implements diaglib.DiagnosticBackend {
  final lines = <String>[];
  @override
  Future<void> initialize(String version, String language) async {}
  @override
  Future<void> append(String message, String? key) async {
    lines.add(message);
  }

  @override
  Future<diaglib.DiagnosticSnapshot> snapshot() async =>
      diaglib.DiagnosticSnapshot(lines: lines, available: true);
}

class Draft {
  String? name;
  bool automatic = false, userSelected = false, changed = false;
  List<String> members = [];
  Set<String> selected = {};
  void choose(String? n, List<String> p, {bool auto = false}) {
    name = n;
    automatic = auto;
    userSelected = !auto;
    changed = false;
    members = List.of(p);
    selected = p.toSet();
  }

  void reconcile(Map<String, List<String>> groups, List<String> project) {
    if (automatic && project.isNotEmpty) {
      name = null;
      automatic = false;
      selected.clear();
      members = [];
    }
    if (name == null) return;
    if (!groups.containsKey(name)) {
      name = null;
      selected.clear();
      members = [];
      automatic = false;
      userSelected = true;
      changed = true;
      return;
    }
    members = List.of(groups[name]!);
    selected.removeWhere((x) => !members.contains(x));
  }

  List<String> ordered() {
    final seen = <String>{};
    return [
      for (final p in members)
        if (selected.contains(p) && seen.add(p)) p,
    ];
  }
}

class Model {
  final groups = <String, List<String>>{};
  String? def;
  List<String> project = ['Alice'];
  Draft? draft;
  Draft getDraft() {
    if (draft == null) {
      draft = Draft();
      if (project.isEmpty && groups.containsKey(def)) {
        draft!.choose(def, groups[def]!, auto: true);
      }
    }
    draft!.reconcile(groups, project);
    return draft!;
  }

  void reconcile() {
    draft?.reconcile(groups, project);
  }
}

String fmt(Object? x) => jsonEncode(x);
void equal(Object? a, Object? b, String what) {
  if (fmt(a) != fmt(b)) {
    throw StateError('$what expected=${fmt(b)} actual=${fmt(a)}');
  }
}

Map<String, List<String>> actualGroups(MobileAppState s) => {
  for (final g in s.playerGroups) g.name: List<String>.of(g.players),
};

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'selected deletion and same-name recreation stays invalid; import deduplicates',
    () async {
      final root = await Directory.systemTemp.createTemp('bhe_p2a_fixed_');
      final backend = FaultPrefs({
        gkey: jsonEncode([
          {
            'name': 'Alpha',
            'players': ['Bob', 'Alice', 'Bob', 'Carol'],
          },
        ]),
      });
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = backend;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => root.path,
          );
      final state = MobileAppState(
        analysisEngine: const MobileAnalysisEngineUnavailable(),
      );
      try {
        await state.ready;
        state.project = state.project.copyWith(players: ['Alice']);
        final draft = state.rosterSelection;
        draft.choose('Alpha', state.playerGroups.single.players);
        equal(draft.orderedPlayers, [
          'Bob',
          'Alice',
          'Carol',
        ], 'legacy duplicate selection');
        expect(await state.importPlayers(draft.orderedPlayers), isTrue);
        equal(state.project.players, [
          'Alice',
          'Bob',
          'Carol',
        ], 'append without duplication and preserve order');
        expect(
          await state.importPlayers(['Carol', 'Bob', 'Dan', 'Dan', 'Alice']),
          isTrue,
        );
        equal(state.project.players, [
          'Alice',
          'Bob',
          'Carol',
          'Dan',
        ], 'dedupe repeated import');
        expect(await state.deletePlayerGroup('Alpha'), isTrue);
        expect(draft.groupChanged, isTrue);
        expect(draft.groupName, isNull);
        expect(await state.savePlayerGroup('Alpha'), isTrue);
        expect(draft.groupName, isNull);
        expect(draft.orderedPlayers, isEmpty);
        expect(draft.groupChanged, isTrue);
      } finally {
        state.dispose();
        SharedPreferences.resetStatic();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              null,
            );
        await root.delete(recursive: true);
      }
    },
  );
  test('queued mutations with a blocked first preference write', () async {
    var singleFaults = 0, twoKeyFaults = 0;
    final variants = <int, int>{};
    final queueCount = regressionSeedCount('P2A_SEED_COUNT');
    for (var seed = 0; seed < queueCount; seed++) {
      final rng = Random(seed + 50000);
      final second = rng.nextInt(3);
      variants[second] = (variants[second] ?? 0) + 1;
      final root = await Directory.systemTemp.createTemp('bhe_p2a_queue_');
      final backend = FaultPrefs({
        gkey: jsonEncode([
          {
            'name': 'Alpha',
            'players': ['Alice', 'Bob'],
          },
        ]),
        dkey: 'Alpha',
      });
      final diag = CapturedDiagnostics(),
          oldDiag = diaglib.MobileDiagnostics.instance;
      diaglib.MobileDiagnostics.instance = diaglib.MobileDiagnostics(diag);
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = backend;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => root.path,
          );
      final state = MobileAppState(
        analysisEngine: const MobileAnalysisEngineUnavailable(),
      );
      try {
        await state.ready;
        final injected = rng.nextInt(3);
        if (injected != 0) {
          backend.failKey = injected == 1 ? gkey : dkey;
          backend.failuresLeft = 1;
        }
        final entered = Completer<void>(), release = Completer<void>();
        backend.entered = entered;
        backend.release = release;
        final first = state.editPlayerGroup('Alpha', 'Beta', ['Bob', 'Alice']);
        await entered.future;
        final Future<bool> next;
        if (second == 0) {
          next = state.setDefaultPlayerGroup(null);
        } else if (second == 1) {
          next = state.renamePlayerGroup('Beta', 'Gamma');
        } else {
          next = state.deletePlayerGroup('Beta');
        }
        var secondFinished = false;
        next.then((_) => secondFinished = true);
        await Future<void>.delayed(Duration.zero);
        equal(actualGroups(state), {
          'Alpha': ['Alice', 'Bob'],
        }, 'seed=$seed pending memory groups');
        equal(
          state.defaultPlayerGroupName,
          'Alpha',
          'seed=$seed pending default',
        );
        equal(secondFinished, false, 'seed=$seed second must queue');
        release.complete();
        final firstOk = await first, secondOk = await next;
        equal(firstOk, injected == 0, 'seed=$seed first result');
        equal(secondOk, second == 0 || firstOk, 'seed=$seed second result');
        final expected = <String, List<String>>{};
        String? expectedDefault;
        if (!firstOk) {
          expected['Alpha'] = ['Alice', 'Bob'];
          expectedDefault = second == 0 ? null : 'Alpha';
          singleFaults++;
          if (injected == 2) twoKeyFaults++;
        } else if (second == 0) {
          expected['Beta'] = ['Bob', 'Alice'];
          expectedDefault = null;
        } else if (second == 1) {
          expected['Gamma'] = ['Bob', 'Alice'];
          expectedDefault = 'Gamma';
        } else {
          expectedDefault = null;
        }
        equal(actualGroups(state), expected, 'seed=$seed groups');
        equal(
          state.defaultPlayerGroupName,
          expectedDefault,
          'seed=$seed default',
        );
        if (!firstOk &&
            !diag.lines.any(
              (line) => line.contains('app error: player.groups'),
            )) {
          throw StateError('seed=$seed diagnostic missing');
        }
        SharedPreferences.resetStatic();
        final restarted = PlayerGroupStore(
          onChanged: () {},
          onFailure: (e, s) => throw StateError('$e'),
        );
        await restarted.ready;
        equal(
          {for (final g in restarted.groups) g.name: g.players},
          expected,
          'seed=$seed restart groups',
        );
        equal(
          restarted.defaultName,
          expectedDefault,
          'seed=$seed restart default',
        );
      } finally {
        state.dispose();
        diaglib.MobileDiagnostics.instance = oldDiag;
        SharedPreferences.resetStatic();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              null,
            );
        await root.delete(recursive: true);
      }
    }
    print(
      'P2A_QUEUE seeds=$queueCount failures=0 injected=$singleFaults second_key=$twoKeyFaults variants=$variants',
    );
  });
  test(
    'default write and subsequent rollback both fail: restart validates dangling default',
    () async {
      final root = await Directory.systemTemp.createTemp('bhe_p2a_double_');
      final backend = FaultPrefs({
        gkey: jsonEncode([
          {
            'name': 'Alpha',
            'players': ['Alice'],
          },
        ]),
        dkey: 'Alpha',
      });
      final diag = CapturedDiagnostics(),
          oldDiag = diaglib.MobileDiagnostics.instance;
      diaglib.MobileDiagnostics.instance = diaglib.MobileDiagnostics(diag);
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = backend;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => root.path,
          );
      final state = MobileAppState(
        analysisEngine: const MobileAnalysisEngineUnavailable(),
      );
      try {
        await state.ready;
        backend.failurePlan.addAll([dkey, gkey]);
        expect(await state.renamePlayerGroup('Alpha', 'Beta'), isFalse);
        equal(actualGroups(state), {
          'Alpha': ['Alice'],
        }, 'memory remains old');
        equal(state.defaultPlayerGroupName, 'Alpha', 'old default');
        final raw = await backend.getAll();
        equal(jsonDecode(raw[gkey] as String), [
          {
            'name': 'Beta',
            'players': ['Alice'],
          },
        ], 'partial groups');
        equal(raw[dkey], 'Alpha', 'old persisted default');
        expect(
          diag.lines
              .where((line) => line.contains('app error: player.groups'))
              .length,
          2,
        );
        SharedPreferences.resetStatic();
        final restarted = PlayerGroupStore(
          onChanged: () {},
          onFailure: (e, s) => throw StateError('$e'),
        );
        await restarted.ready;
        equal(
          {for (final g in restarted.groups) g.name: g.players},
          {
            'Beta': ['Alice'],
          },
          'restart groups',
        );
        equal(restarted.defaultName, null, 'restart validation');
        equal(
          (await backend.getAll()).containsKey(dkey),
          false,
          'stale default cleared',
        );
      } finally {
        state.dispose();
        diaglib.MobileDiagnostics.instance = oldDiag;
        SharedPreferences.resetStatic();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              null,
            );
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'fixed seeds: groups, draft, project and preference restart against a model',
    () async {
      final results = <Map<String, Object?>>[], coverage = <String, int>{};
      final failures = <Map<String, Object?>>[];
      final start =
              int.tryParse(Platform.environment['P2A_START_SEED'] ?? '') ?? 0,
          count = regressionSeedCount('P2A_SEED_COUNT'),
          steps = int.tryParse(Platform.environment['P2A_STEPS'] ?? '') ?? 35;
      for (var seed = start; seed < start + count; seed++) {
        final rng = Random(seed), trace = <String>[];
        var injected = 0, delayed = 0, effective = 0;
        final root = await Directory.systemTemp.createTemp('bhe_p2a_fuzz_');
        final backend = FaultPrefs({
          gkey: jsonEncode([
            {
              'name': 'Alpha',
              'players': ['Bob', 'Alice', 'Bob'],
            },
          ]),
          dkey: 'Alpha',
        });
        final diag = CapturedDiagnostics();
        final oldDiag = diaglib.MobileDiagnostics.instance;
        diaglib.MobileDiagnostics.instance = diaglib.MobileDiagnostics(diag);
        SharedPreferences.resetStatic();
        SharedPreferencesStorePlatform.instance = backend;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async => root.path,
            );
        final engine = RecordingAnalysis();
        final state = MobileAppState(
          analysisEngine: engine,
          videoProbe: MobileVideoFixture.inspect,
        );
        try {
          await state.ready;
          final video = await File(
            '${root.path}/source.mp4',
          ).writeAsString('original');
          final f = MobileVideoFixture();
          state.project = f.project(video.path).copyWith(candidates: []);
          final model = Model()
            ..groups['Alpha'] = ['Bob', 'Alice', 'Bob']
            ..def = 'Alpha';
          for (var step = 0; step < steps; step++) {
            final op = rng.nextInt(13),
                name = names[rng.nextInt(names.length)],
                other = names[rng.nextInt(names.length)],
                player = players[rng.nextInt(players.length)];
            final kind = [
              'save',
              'replace',
              'rename',
              'delete',
              'edit',
              'set_default',
              'clear_default',
              'choose',
              'toggle',
              'analysis',
              'rename_player',
              'remove_player',
              'switch',
            ][op];
            coverage[kind] = (coverage[kind] ?? 0) + 1;
            final before = backend.hits,
                beforeDelay = backend.delayHits,
                beforeDiag = diag.lines.length;
            backend.failKey = op <= 6 && rng.nextInt(4) == 0
                ? (rng.nextBool() ? gkey : dkey)
                : null;
            backend.failuresLeft = backend.failKey == null ? 0 : 1;
            backend.delay = rng.nextInt(5) == 0;
            trace.add(
              '$step $kind name=$name other=$other player=$player fail=${backend.failKey} delay=${backend.delay}',
            );
            var success = true, valid = true;
            switch (op) {
              case 0:
              case 1:
                valid = op == 1 || !model.groups.containsKey(name);
                success = await state.savePlayerGroup(
                  name,
                  replaceExisting: op == 1,
                );
                if (success) model.groups[name] = List.of(model.project);
              case 2:
                valid =
                    model.groups.containsKey(name) &&
                    (!model.groups.containsKey(other) || name == other);
                success = await state.renamePlayerGroup(name, other);
                if (success) {
                  final entries = model.groups.entries
                      .map(
                        (e) => MapEntry(e.key == name ? other : e.key, e.value),
                      )
                      .toList();
                  model.groups
                    ..clear()
                    ..addEntries(entries);
                  if (model.def == name) model.def = other;
                }
              case 3:
                valid = model.groups.containsKey(name);
                if (valid && model.draft?.name == name) {
                  coverage['delete_selected_group'] =
                      (coverage['delete_selected_group'] ?? 0) + 1;
                }
                success = await state.deletePlayerGroup(name);
                if (success) {
                  model.groups.remove(name);
                  if (model.def == name) model.def = null;
                }
              case 4:
                final members = [...players]..shuffle(rng);
                final chosen = members.take(rng.nextInt(4)).toList();
                trace.add('  edit_members=$chosen');
                valid = model.groups.containsKey(name);
                success = await state.editPlayerGroup(name, name, chosen);
                if (success) model.groups[name] = chosen;
              case 5:
                valid = model.groups.containsKey(name);
                success = await state.setDefaultPlayerGroup(name);
                if (success) model.def = name;
              case 6:
                success = await state.setDefaultPlayerGroup(null);
                if (success) model.def = null;
              case 7:
                final d = state.rosterSelection, m = model.getDraft();
                final target = model.groups.containsKey(name) ? name : null;
                final list = target == null
                    ? <String>[]
                    : model.groups[target]!;
                d.choose(target, list);
                m.choose(target, list);
              case 8:
                final d = state.rosterSelection, m = model.getDraft();
                if (m.members.contains(player)) {
                  if (m.selected.contains(player)) {
                    m.selected.remove(player);
                    d.selected.remove(player);
                  } else {
                    m.selected.add(player);
                    d.selected.add(player);
                  }
                }
              case 9:
                final d = state.rosterSelection, m = model.getDraft();
                final selected = m.ordered();
                final chosen = m.name;
                final beforePlayers = List<String>.of(model.project);
                final beforeCalls = engine.calls;
                if (selected.any((p) => beforePlayers.contains(p))) {
                  coverage['analysis_existing_player'] =
                      (coverage['analysis_existing_player'] ?? 0) + 1;
                }
                if (selected.any((p) => !beforePlayers.contains(p))) {
                  coverage['analysis_append_player'] =
                      (coverage['analysis_append_player'] ?? 0) + 1;
                }
                await state.startAnalysis(
                  rosterPlayers: selected,
                  expectedRosterGroup: chosen,
                  expectedProjectId: state.project.id,
                  expectedSession: state.projectSession,
                  expectedVideoGeneration: state.videoPreparationGeneration,
                );
                if (chosen != null && !m.changed) {
                  for (final x in selected) {
                    if (!model.project.contains(x)) model.project.add(x);
                  }
                } else if (chosen == null) {
                  for (final x in selected) {
                    if (!model.project.contains(x)) model.project.add(x);
                  }
                }
                equal(engine.calls, beforeCalls + 1, 'analysis engine called');
                equal(
                  model.project.take(beforePlayers.length).toList(),
                  beforePlayers,
                  'import preserves order',
                );
                equal(d.orderedPlayers, m.ordered(), 'draft post analysis');
              case 10:
                final newName = players[rng.nextInt(players.length)];
                trace.add('  rename_to=$newName');
                valid =
                    model.project.contains(player) &&
                    (!model.project.contains(newName) || player == newName);
                success = await state.renamePlayer(player, newName);
                if (success) {
                  model.project = [
                    for (final p in model.project)
                      if (p == player) newName else p,
                  ];
                }
              case 11:
                valid = model.project.contains(player);
                success = await state.removePlayer(player);
                if (success) model.project.remove(player);
              case 12:
                await state.createNewProject();
                final id = state.project.id;
                state.project = f
                    .project(video.path, id: id)
                    .copyWith(players: [], candidates: []);
                model.project = [];
                model.draft = null;
            }
            delayed += backend.delayHits - beforeDelay;
            final wasInjected = backend.hits > before;
            if (wasInjected) {
              injected++;
              final fault = backend.failKey == dkey
                  ? 'fault_default_key'
                  : 'fault_groups_key';
              coverage[fault] = (coverage[fault] ?? 0) + 1;
              equal(success, false, 'fault must fail');
              if (!diag.lines
                  .skip(beforeDiag)
                  .any((line) => line.contains('app error: player.groups'))) {
                throw StateError(
                  'missing MobileDiagnostics for failed preference',
                );
              }
            } else if (op <= 6 || op == 10 || op == 11) {
              equal(success, valid, 'operation result');
            }
            if (success) effective++;
            model.reconcile();
            equal(actualGroups(state), model.groups, 'groups');
            equal(state.defaultPlayerGroupName, model.def, 'default');
            equal(state.project.players, model.project, 'project players');
            final d = state.rosterSelection, m = model.getDraft();
            equal(d.groupName, m.name, 'draft name');
            equal(d.orderedPlayers, m.ordered(), 'draft ordered');
            equal(d.groupChanged, m.changed, 'draft changed');
            equal(d.automatic, m.automatic, 'draft automatic');
            equal(d.userSelected, m.userSelected, 'draft user selected');
            equal(
              (d.selected.toList()..sort()),
              (m.selected.toList()..sort()),
              'draft selected',
            );
            if (state.defaultPlayerGroupName != null &&
                !actualGroups(
                  state,
                ).containsKey(state.defaultPlayerGroupName)) {
              throw StateError('dangling default');
            }
            backend.failKey = null;
            backend.failuresLeft = 0;
            backend.delay = false;
            SharedPreferences.resetStatic();
            final restarted = PlayerGroupStore(
              onChanged: () {},
              onFailure: (e, s) => throw StateError('restart failure: $e'),
            );
            await restarted.ready;
            equal(
              {for (final g in restarted.groups) g.name: g.players},
              model.groups,
              'restart groups',
            );
            equal(restarted.defaultName, model.def, 'restart default');
          }
        } catch (e, st) {
          failures.add({
            'seed': seed,
            'error': '$e',
            'trace': trace,
            'stack': '$st',
          });
        } finally {
          state.dispose();
          diaglib.MobileDiagnostics.instance = oldDiag;
          SharedPreferences.resetStatic();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                null,
              );
          await root.delete(recursive: true);
        }
        results.add({
          'seed': seed,
          'steps_reached': trace.where((x) => !x.startsWith('  ')).length,
          'injected': injected,
          'delayed': delayed,
          'effective': effective,
        });
      }
      final path = Platform.environment['P2A_RESULTS'];
      final result = {
        'base': 'current checkout',
        'seed_start': start,
        'seed_count': count,
        'steps': steps,
        'coverage': coverage,
        'results': results,
        'failures': failures,
      };
      if (path != null) {
        await File(
          path,
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
      }
      print(
        'P2A_SUMMARY seeds=$count failures=${failures.length} injected=${results.fold<int>(0, (a, b) => a + (b['injected'] as int))} delayed=${results.fold<int>(0, (a, b) => a + (b['delayed'] as int))} coverage=$coverage',
      );
      if (failures.isNotEmpty) {
        print(
          'FAILING_SEEDS ${failures.map((failure) => failure['seed']).join(',')}\nFIRST_FAILURE ${jsonEncode(failures.first)}',
        );
      }
      expect(
        failures,
        isEmpty,
        reason: 'see P2A_RESULTS for seed and failing prefix',
      );
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
