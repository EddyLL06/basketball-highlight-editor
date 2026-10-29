import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bhe_mobile/mobile_app_state.dart';
import 'dart:io';
import 'dart:convert';
import '../../support/mobile_video_fixture.dart';
import '../video_source/analysis_validation_test.dart' show RecordingAnalysis;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'default group is suggested only for empty project and draft keeps group order',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        f.state.project = f.project('missing').copyWith(players: []);
        f.state.playerGroups = [
          (name: 'Team', players: ['B', 'A', 'B', 'C']),
        ];
        f.state.defaultPlayerGroupName = 'Team';
        final draft = f.state.rosterSelection;
        expect(draft.groupName, 'Team');
        draft.selected.remove('A');
        expect(draft.orderedPlayers, ['B', 'C']);
        draft.selected.add('A');
        expect(draft.orderedPlayers, ['B', 'A', 'C']);
        draft.choose(null, const []);
        expect(f.state.rosterSelection.groupName, isNull);
        await f.state.createNewProject();
        expect(f.state.rosterSelection.groupName, 'Team');
      } finally {
        await f.close();
      }
    },
  );

  test(
    'existing players prevent automatic default; manual import appends without duplicates',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        f.state.project = f.project('missing');
        f.state.playerGroups = [
          (name: 'Team', players: ['Alice', 'Bob', 'Bob', 'Carol']),
        ];
        f.state.defaultPlayerGroupName = 'Team';
        expect(f.state.rosterSelection.groupName, isNull);
        expect(
          await f.state.importPlayers(['Alice', 'Bob', 'Bob', 'Carol']),
          isTrue,
        );
        expect(f.state.project.players, ['Alice', 'Bob', 'Carol']);
        expect(await f.state.importPlayers(['Carol', 'Bob']), isTrue);
        expect(f.state.project.players, ['Alice', 'Bob', 'Carol']);
      } finally {
        await f.close();
      }
    },
  );

  test(
    'failed roster save does not clear candidates or start analysis',
    () async {
      final f = MobileVideoFixture();
      final engine = RecordingAnalysis();
      await f.init(engine: engine);
      try {
        final video = await f.file('original.mp4', 'original');
        f.state.project = f.project(video.path).copyWith(players: []);
        f.state.playerGroups = [
          (name: 'Team', players: ['Bob']),
        ];
        var first = true;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async {
                if (first) {
                  first = false;
                  throw PlatformException(code: 'roster_save_failed');
                }
                return f.root.path;
              },
            );
        await f.state.startAnalysis(
          rosterPlayers: ['Bob'],
          expectedRosterGroup: 'Team',
          expectedProjectId: f.state.project.id,
          expectedSession: f.state.projectSession,
          expectedVideoGeneration: f.state.videoPreparationGeneration,
        );
        expect(engine.calls, 0);
        expect(f.state.project.players, isEmpty);
        expect(f.state.project.candidates.single.id, 'goal');
        expect(f.state.diagnosticError, isNotNull);
        expect(f.state.analysing, isFalse);
      } finally {
        await f.close();
      }
    },
  );

  test(
    'analysis imports checked roster after video validation in stable order',
    () async {
      final f = MobileVideoFixture();
      final engine = RecordingAnalysis();
      await f.init(engine: engine);
      try {
        final video = await f.file('original.mp4', 'original');
        f.state.project = f.project(video.path).copyWith(players: ['Alice']);
        f.state.playerGroups = [
          (name: 'Team', players: ['Bob', 'Carol', 'Bob', 'Alice']),
        ];
        await f.state.startAnalysis(
          rosterPlayers: ['Carol', 'Bob'],
          expectedRosterGroup: 'Team',
          expectedProjectId: f.state.project.id,
          expectedSession: f.state.projectSession,
          expectedVideoGeneration: f.state.videoPreparationGeneration,
        );
        expect(engine.calls, 1);
        expect(f.state.project.players, ['Alice', 'Bob', 'Carol']);
      } finally {
        await f.close();
      }
    },
  );

  test(
    'legacy groups and default preference load without rewriting data',
    () async {
      final dir = await Directory.systemTemp.createTemp('roster_prefs_');
      try {
        final raw = jsonEncode([
          {
            'name': 'Old',
            'players': ['B', 'A', 'B'],
          },
        ]);
        SharedPreferences.setMockInitialValues({
          MobileAppState.playerGroupsPrefsKey: raw,
          MobileAppState.defaultPlayerGroupPrefsKey: 'Old',
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async => dir.path,
            );
        final state = MobileAppState(
          analysisEngine: const MobileAnalysisEngineUnavailable(),
        );
        await state.ready;
        expect(state.rosterSelection.groupName, 'Old');
        expect(state.rosterSelection.orderedPlayers, ['B', 'A']);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(MobileAppState.playerGroupsPrefsKey), raw);
        state.dispose();
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              null,
            );
        await dir.delete(recursive: true);
      }
    },
  );
}
