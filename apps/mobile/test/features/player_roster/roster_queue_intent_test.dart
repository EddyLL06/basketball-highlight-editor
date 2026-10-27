import 'dart:async';
import 'dart:io';
import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/mobile_video_fixture.dart';
import '../video_source/analysis_validation_test.dart' show RecordingAnalysis;

class SlowCancelAnalysis extends RecordingAnalysis {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> cancel() async {
    entered.complete();
    await release.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final reason in ['cancel', 'replace', 'delete', 'recreate', 'switch']) {
    test('queued roster is discarded after $reason', () async {
      final f = MobileVideoFixture();
      final engine = RecordingAnalysis();
      await f.init(engine: engine);
      final release = Completer<void>();
      try {
        final source = await f.file('original.mp4', 'original');
        f.state.project = f.project(source.path).copyWith(players: []);
        f.state.playerGroups = [
          (name: 'Team', players: ['Bob']),
        ];
        f.state.rosterSelection.choose('Team', ['Bob']);
        expect(await f.state.renameProject('Baseline'), isTrue);
        final entered = Completer<void>();
        var first = true;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async {
                if (first) {
                  first = false;
                  entered.complete();
                  await release.future;
                }
                return f.root.path;
              },
            );
        final review = f.state.updateCandidateNote('goal', 'keep');
        await entered.future;
        final analysis = f.state.startAnalysis(
          rosterPlayers: ['Bob'],
          expectedRosterGroup: 'Team',
          expectedProjectId: f.state.project.id,
          expectedSession: f.state.projectSession,
          expectedVideoGeneration: f.state.videoPreparationGeneration,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        Future<void>? pending;
        Future<bool>? recreate;
        switch (reason) {
          case 'cancel':
            pending = f.state.cancelAnalysis();
          case 'replace':
            f.choose(source);
            pending = f.state.relinkVideo();
          case 'delete':
            expect(await f.state.deletePlayerGroup('Team'), isTrue);
          case 'recreate':
            expect(await f.state.deletePlayerGroup('Team'), isTrue);
            recreate = f.state.savePlayerGroup('Team');
          case 'switch':
            pending = f.state.createNewProject();
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
        release.complete();
        expect(await review, isTrue);
        await analysis;
        await pending;
        if (recreate != null) expect(await recreate, isTrue);
        final disk = const ProjectPackageCodec().decode(
          await File('${f.data.path}/projects/A.json').readAsString(),
        );
        expect(disk.players, isEmpty);
        expect(disk.candidates.single.note, 'keep');
        expect(engine.calls, 0);
        if (reason != 'switch') {
          expect(f.state.project.players, isEmpty);
          expect(f.state.project.candidates.single.note, 'keep');
          if (reason != 'replace') expect(f.state.canUndoReview, isTrue);
        }
      } finally {
        if (!release.isCompleted) release.complete();
        await f.close();
      }
    });
  }
  test('save group waits for earlier project player mutation', () async {
    final f = MobileVideoFixture();
    await f.init();
    final release = Completer<void>();
    try {
      final source = await f.file('original.mp4', 'original');
      f.state.project = f.project(source.path);
      final entered = Completer<void>();
      var first = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async {
              if (first) {
                first = false;
                entered.complete();
                await release.future;
              }
              return f.root.path;
            },
          );
      final add = f.state.addPlayer('Bob');
      await entered.future;
      final save = f.state.savePlayerGroup('Team');
      release.complete();
      expect(await add, isTrue);
      expect(await save, isTrue);
      expect(f.state.playerGroups.single.players, ['Alice', 'Bob']);
      final disk = const ProjectPackageCodec().decode(
        await File('${f.data.path}/projects/A.json').readAsString(),
      );
      expect(disk.players, ['Alice', 'Bob']);
    } finally {
      if (!release.isCompleted) release.complete();
      await f.close();
    }
  });
  test(
    'cancel waits for an already-started roster commit without overwriting later edits',
    () async {
      final f = MobileVideoFixture();
      final engine = RecordingAnalysis();
      await f.init(engine: engine);
      final release = Completer<void>();
      try {
        final source = await f.file('original.mp4', 'original');
        f.state.project = f.project(source.path).copyWith(players: []);
        f.state.playerGroups = [
          (name: 'Team', players: ['Bob']),
        ];
        f.state.rosterSelection.choose('Team', ['Bob']);
        final entered = Completer<void>();
        var first = true;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async {
                if (first) {
                  first = false;
                  entered.complete();
                  await release.future;
                }
                return f.root.path;
              },
            );
        final analysis = f.state.startAnalysis(
          rosterPlayers: ['Bob'],
          expectedRosterGroup: 'Team',
        );
        await entered.future;
        final cancel = f.state.cancelAnalysis();
        final later = f.state.addPlayer('Carol');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        release.complete();
        await analysis;
        await cancel;
        expect(await later, isTrue);
        expect(engine.calls, 0);
        expect(f.state.project.players, ['Bob', 'Carol']);
        final disk = const ProjectPackageCodec().decode(
          await File('${f.data.path}/projects/A.json').readAsString(),
        );
        expect(disk.players, ['Bob', 'Carol']);
      } finally {
        if (!release.isCompleted) release.complete();
        await f.close();
      }
    },
  );
  test(
    'F5 rename is independent: selected old group name can be appended again',
    () async {
      final f = MobileVideoFixture();
      final engine = RecordingAnalysis();
      await f.init(engine: engine);
      try {
        final source = await f.file('original.mp4', 'original');
        f.state.project = f.project(source.path);
        f.state.playerGroups = [
          (name: 'Team', players: ['Alice']),
        ];
        expect(await f.state.renamePlayer('Alice', 'Carol'), isTrue);
        expect(f.state.playerGroups.single.players, ['Alice']);
        f.state.rosterSelection.choose('Team', ['Alice']);
        await f.state.startAnalysis(
          rosterPlayers: f.state.rosterSelection.orderedPlayers,
          expectedRosterGroup: 'Team',
        );
        expect(engine.calls, 1);
        expect(f.state.project.players, ['Carol', 'Alice']);
        final disk = const ProjectPackageCodec().decode(
          await File('${f.data.path}/projects/A.json').readAsString(),
        );
        expect(disk.players, ['Carol', 'Alice']);
      } finally {
        await f.close();
      }
    },
  );
  test(
    'cancel intent invalidates queued roster before native cancel returns',
    () async {
      final f = MobileVideoFixture();
      final engine = SlowCancelAnalysis();
      await f.init(engine: engine);
      final release = Completer<void>();
      try {
        final source = await f.file('original.mp4', 'original');
        f.state.project = f.project(source.path).copyWith(players: []);
        f.state.playerGroups = [
          (name: 'Team', players: ['Bob']),
        ];
        final entered = Completer<void>();
        var first = true;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async {
                if (first) {
                  first = false;
                  entered.complete();
                  await release.future;
                }
                return f.root.path;
              },
            );
        final review = f.state.updateCandidateNote('goal', 'keep');
        await entered.future;
        final analysis = f.state.startAnalysis(
          rosterPlayers: ['Bob'],
          expectedRosterGroup: 'Team',
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final cancel = f.state.cancelAnalysis();
        await engine.entered.future;
        release.complete();
        expect(await review, isTrue);
        await analysis;
        expect(f.state.project.players, isEmpty);
        expect(engine.calls, 0);
        final disk = const ProjectPackageCodec().decode(
          await File('${f.data.path}/projects/A.json').readAsString(),
        );
        expect(disk.players, isEmpty);
        expect(disk.candidates.single.note, 'keep');
        engine.release.complete();
        await cancel;
      } finally {
        if (!release.isCompleted) release.complete();
        if (!engine.release.isCompleted) engine.release.complete();
        await f.close();
      }
    },
  );
  test(
    'failed roster transaction preserves disk, candidates and undo history',
    () async {
      final f = MobileVideoFixture();
      final engine = RecordingAnalysis();
      await f.init(engine: engine);
      try {
        final source = await f.file('original.mp4', 'original');
        f.state.project = f.project(source.path).copyWith(players: []);
        f.state.playerGroups = [
          (name: 'Team', players: ['Bob']),
        ];
        expect(await f.state.updateCandidateNote('goal', 'keep'), isTrue);
        final notice = f.state.reviewNotice;
        var first = true;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async {
                if (first) {
                  first = false;
                  throw PlatformException(code: 'roster_io_failed');
                }
                return f.root.path;
              },
            );
        await f.state.startAnalysis(
          rosterPlayers: ['Bob'],
          expectedRosterGroup: 'Team',
        );
        expect(engine.calls, 0);
        expect(f.state.project.players, isEmpty);
        expect(f.state.project.candidates.single.note, 'keep');
        expect(f.state.canUndoReview, isTrue);
        expect(f.state.reviewNotice, notice);
        expect(f.state.diagnosticError, isNotNull);
        final disk = const ProjectPackageCodec().decode(
          await File('${f.data.path}/projects/A.json').readAsString(),
        );
        expect(disk.players, isEmpty);
        expect(disk.candidates.single.note, 'keep');
      } finally {
        await f.close();
      }
    },
  );
  test('video validation failure preserves roster, disk and history', () async {
    final f = MobileVideoFixture();
    final engine = RecordingAnalysis();
    await f.init(engine: engine);
    try {
      final source = await f.file('original.mp4', 'original');
      f.state.project = f.project(source.path).copyWith(players: []);
      f.state.playerGroups = [
        (name: 'Team', players: ['Bob']),
      ];
      expect(await f.state.updateCandidateNote('goal', 'keep'), isTrue);
      await source.delete();
      await f.state.startAnalysis(
        rosterPlayers: ['Bob'],
        expectedRosterGroup: 'Team',
      );
      expect(engine.calls, 0);
      expect(f.state.project.players, isEmpty);
      expect(f.state.project.candidates.single.note, 'keep');
      expect(f.state.canUndoReview, isTrue);
      final disk = const ProjectPackageCodec().decode(
        await File('${f.data.path}/projects/A.json').readAsString(),
      );
      expect(disk.players, isEmpty);
      expect(disk.candidates.single.note, 'keep');
    } finally {
      await f.close();
    }
  });
}
