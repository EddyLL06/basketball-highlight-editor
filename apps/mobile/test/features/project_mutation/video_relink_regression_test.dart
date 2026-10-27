import 'dart:async';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'relink preserves reviews made while picker is open and clears history',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        f.state.project = f.project('${f.root.path}/missing.mp4');
        f.state.recentProjects = [f.state.project];
        expect(await f.state.updateCandidateNote('goal', 'before'), isTrue);
        final entered = Completer<void>();
        final result = Completer<FilePickerResult?>();
        f.picker.pick = () {
          entered.complete();
          return result.future;
        };
        final pending = f.state.relinkVideo();
        await entered.future;
        expect(await f.state.updateCandidateNote('goal', 'after'), isTrue);
        final chosen = await f.file('chosen.mp4', 'original');
        result.complete(
          FilePickerResult([
            PlatformFile(name: 'chosen.mp4', path: chosen.path, size: 8),
          ]),
        );
        await pending;
        final disk = const ProjectPackageCodec().decode(
          await File('${f.data.path}/projects/A.json').readAsString(),
        );
        expect(f.state.project.candidates.single.note, 'after');
        expect(disk.candidates.single.note, 'after');
        expect(f.state.canUndoReview, isFalse);
        expect(f.state.reviewNotice, isNull);
      } finally {
        await f.close();
      }
    },
  );

  test('cancelled or mismatched relink preserves undo and notice', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      f.state.project = f.project('${f.root.path}/missing.mp4');
      expect(await f.state.updateCandidateNote('goal', 'protected'), isTrue);
      final notice = f.state.reviewNotice;
      f.choose(null);
      await f.state.relinkVideo();
      expect(f.state.canUndoReview, isTrue);
      expect(f.state.reviewNotice, notice);
      f.choose(await f.file('wrong.mp4', 'not original'));
      await f.state.relinkVideo();
      expect(f.state.canUndoReview, isTrue);
      expect(f.state.reviewNotice, notice);
      expect(f.state.project.candidates.single.note, 'protected');
    } finally {
      await f.close();
    }
  });
}
