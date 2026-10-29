import 'dart:io';
import 'dart:convert';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/review_undo/review_history.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'rename validates, updates every candidate, history and project package',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        final source = await f.file('original.mp4', 'original');
        final base = f.project(source.path);
        f.state.project = base.copyWith(
          players: ['Alice', 'Bob'],
          candidates: [
            ...base.candidates,
            const Candidate(
              id: 'two',
              startMs: 10,
              endMs: 20,
              eventMs: 15,
              player: 'Alice',
            ),
          ],
        );
        await f.state.savePlayerGroup('team');
        expect(await f.state.renamePlayer('Alice', '  '), isFalse);
        expect(await f.state.renamePlayer('Alice', ' Bob '), isFalse);
        await f.state.setCandidatePlayer('goal', 'Bob');
        expect(await f.state.renamePlayer('Alice', ' Carol '), isTrue);
        expect(f.state.project.players, ['Carol', 'Bob']);
        expect(f.state.project.candidates.last.player, 'Carol');
        expect(f.state.playerGroups.single.players, ['Alice', 'Bob']);
        await f.state.undoReview();
        expect(f.state.project.candidates.first.player, 'Carol');
        final decoded = const ProjectPackageCodec().decode(
          const ProjectPackageCodec().encode(f.state.project),
        );
        expect(decoded.candidates.map((c) => c.player), ['Carol', 'Carol']);
        expect(decoded.players, ['Carol', 'Bob']);
        final saved = const ProjectPackageCodec().decode(
          await File('${f.data.path}/projects/A.json').readAsString(),
        );
        expect(saved.players, ['Carol', 'Bob']);
      } finally {
        await f.close();
      }
    },
  );
  test(
    'delete clears references and prevents undo resurrecting a deleted player',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        final source = await f.file('original.mp4', 'original');
        f.state.project = f.project(source.path);
        await f.state.setCandidatePlayer('goal', null);
        await f.state.removePlayer('Alice');
        await f.state.undoReview();
        expect(f.state.project.candidates.single.player, isNull);
        expect(f.state.project.players, isEmpty);
        await f.state.addPlayer('unused');
        await f.state.removePlayer('unused');
        expect(f.state.project.players, isEmpty);
        await f.state.createNewProject();
      } finally {
        await f.close();
      }
    },
  );
  test('legacy version one project remains readable after rename', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      final encoded = jsonEncode({
        'format': 'bhe-project',
        'version': 1,
        'project': {
          'id': 'legacy',
          'name': 'Legacy',
          'players': ['Alice'],
          'candidates': [
            {
              'id': 'goal',
              'start_ms': 100,
              'end_ms': 1000,
              'event_ms': 500,
              'player': 'Alice',
            },
          ],
        },
      });
      f.state.project = const ProjectPackageCodec().decode(encoded);
      expect(await f.state.renamePlayer('Alice', 'Carol'), isTrue);
      final restored = const ProjectPackageCodec().decode(
        const ProjectPackageCodec().encode(f.state.project),
      );
      expect(restored.players, ['Carol']);
      expect(restored.candidates.single.player, 'Carol');
      await f.state.openProject('legacy');
    } finally {
      await f.close();
    }
  });
  test('rename and delete update an undo that is being saved', () {
    final history = ReviewHistory();
    const old = Candidate(
      id: 'c',
      startMs: 0,
      endMs: 1,
      eventMs: 0,
      player: 'Alice',
    );
    history.add(
      ReviewEntry(ReviewChange.player, {
        'c': ReviewFields.capture(ReviewChange.player, old),
      }, 'c'),
    );
    final pending = history.pop()!;
    history.remapPlayer('Alice', 'Carol');
    expect(pending.before['c']!.player, 'Carol');
    history.remapPlayer('Carol', null);
    expect(pending.before['c']!.player, isNull);
    expect(history.restore(pending), isTrue);
    expect(history.canUndo, isTrue);
  });
}
