import 'dart:io';
import 'dart:async';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/review_undo/review_history.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('review edits undo in reverse order and persist', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      final video = await f.file('original.mp4', 'original');
      f.state.project = f.project(video.path);
      await f.state.toggleCandidate('goal', CandidateSelection.excluded);
      await f.state.setCandidatePlayer('goal', null);
      await f.state.updateCandidateNote('goal', 'note');
      await f.state.updateCandidate(
        f.state.project.candidates.single.copyWith(startMs: 500),
      );
      await f.state.undoReview();
      expect(f.state.project.candidates.single.startMs, 1000);
      await f.state.undoReview();
      expect(f.state.project.candidates.single.note, isNull);
      await f.state.undoReview();
      expect(f.state.project.candidates.single.player, 'Alice');
      await f.state.undoReview();
      expect(
        f.state.project.candidates.single.selection,
        CandidateSelection.included,
      );
      expect(f.state.undoFocusId, 'goal');
      expect(f.state.canUndoReview, false);
      final saved = const ProjectPackageCodec().decode(
        await File('${f.data.path}/projects/A.json').readAsString(),
      );
      expect(saved.candidates.single.player, 'Alice');
      expect(saved.candidates.single.selection, CandidateSelection.included);
    } finally {
      await f.close();
    }
  });
  test('history is limited and project switch clears it', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      final video = await f.file('original.mp4', 'original');
      f.state.project = f.project(video.path);
      for (var i = 0; i < 21; i++) {
        await f.state.updateCandidateNote('goal', '$i');
      }
      for (var i = 0; i < 20; i++) {
        await f.state.undoReview();
      }
      expect(f.state.project.candidates.single.note, '0');
      expect(f.state.canUndoReview, false);
      await f.state.updateCandidateNote('goal', 'again');
      await f.state.createNewProject();
      expect(f.state.canUndoReview, false);
    } finally {
      await f.close();
    }
  });
  test('batch range is one step and restores each candidate', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      final video = await f.file('original.mp4', 'original');
      final base = f.project(video.path);
      f.state.project = base.copyWith(
        candidates: [
          ...base.candidates,
          const Candidate(
            id: 'second',
            startMs: 4000,
            endMs: 6000,
            eventMs: 5000,
          ),
        ],
      );
      expect(
        await f.state.applyBatchClipRange(
          beforeSeconds: 2,
          afterSeconds: 2,
          overwriteManual: true,
          focusId: 'second',
        ),
        2,
      );
      await f.state.undoReview();
      expect(f.state.undoFocusId, 'second');
      expect(f.state.project.candidates.map((c) => c.startMs), [1000, 4000]);
      expect(f.state.project.candidates.first.rangeEdited, isTrue);
      expect(f.state.canUndoReview, isFalse);
    } finally {
      await f.close();
    }
  });
  test('failed undo save restores the action for retry', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      final video = await f.file('original.mp4', 'original');
      f.state.project = f.project(video.path);
      await f.state.toggleCandidate('goal', CandidateSelection.excluded);
      final saved = File('${f.data.path}/projects/A.json');
      for (var i = 0; i < 100 && !await saved.exists(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await saved.exists(), isTrue);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => throw PlatformException(code: 'unavailable'),
          );
      final notices = <String?>[];
      f.state.addListener(() => notices.add(f.state.reviewNotice));
      await f.state.undoReview();
      expect(notices, isNot(contains('已撤销')));
      expect(
        f.state.project.candidates.single.selection,
        CandidateSelection.excluded,
      );
      expect(f.state.canUndoReview, isTrue);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => f.root.path,
          );
      await f.state.undoReview();
      expect(
        f.state.project.candidates.single.selection,
        CandidateSelection.included,
      );
      expect(f.state.canUndoReview, isFalse);
    } finally {
      await f.close();
    }
  });
  test(
    'failed undo after a later edit preserves both history entries',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        final video = await f.file('original.mp4', 'original');
        f.state.project = f.project(video.path);
        await f.state.toggleCandidate('goal', CandidateSelection.excluded);
        final saved = File('${f.data.path}/projects/A.json');
        for (var i = 0; i < 100 && !await saved.exists(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final entered = Completer<void>();
        final release = Completer<void>();
        var first = true;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async {
                if (first) {
                  first = false;
                  entered.complete();
                  await release.future;
                  throw PlatformException(code: 'unavailable');
                }
                return f.root.path;
              },
            );
        final undo = f.state.undoReview();
        await entered.future;
        final later = f.state.updateCandidateNote('goal', 'later');
        release.complete();
        await undo;
        await later;
        expect(f.state.diagnosticError, isNotNull);
        expect(f.state.project.candidates.single.note, 'later');
        await f.state.undoReview();
        expect(f.state.project.candidates.single.note, isNull);
        expect(f.state.canUndoReview, isTrue);
        await f.state.undoReview();
        expect(
          f.state.project.candidates.single.selection,
          CandidateSelection.included,
        );
        expect(f.state.canUndoReview, isFalse);
      } finally {
        await f.close();
      }
    },
  );
  test('clearing a session invalidates pending undo completion', () {
    final history = ReviewHistory();
    const candidate = Candidate(id: 'c', startMs: 0, endMs: 1, eventMs: 0);
    history.add(
      ReviewEntry(ReviewChange.selection, {
        'c': ReviewFields.capture(ReviewChange.selection, candidate),
      }, 'c'),
    );
    final entry = history.pop()!;
    history.clear();
    expect(history.complete(entry), isFalse);
    expect(history.restore(entry), isFalse);
    expect(history.canUndo, isFalse);
  });
}
