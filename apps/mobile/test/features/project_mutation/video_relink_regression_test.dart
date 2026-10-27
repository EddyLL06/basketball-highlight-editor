import 'dart:async';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

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

  for (final outcome in ['success', 'cancel', 'failure']) {
    test(
      'relink $outcome during project write preserves later review',
      () async {
        final f = MobileVideoFixture();
        await f.init();
        try {
          f.state.project = f.project('${f.root.path}/missing.mp4');
          expect(await f.state.updateCandidateNote('goal', 'before'), isTrue);
          final chosen = await f.file('chosen.mp4', 'original');
          f.choose(chosen);
          final entered = Completer<void>(), release = Completer<void>();
          var documentsCalls = 0;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                (call) async {
                  if (call.method == 'getApplicationDocumentsDirectory' &&
                      ++documentsCalls == 2) {
                    entered.complete();
                    await release.future;
                    if (outcome == 'failure') {
                      throw PlatformException(
                        code: 'video_metadata_write_failure',
                      );
                    }
                  }
                  return f.root.path;
                },
              );
          final relink = f.state.relinkVideo();
          await entered.future.timeout(const Duration(seconds: 5));
          final later = f.state.updateCandidateNote('goal', 'after');
          if (outcome == 'cancel') f.state.cancelVideoRelink();
          release.complete();
          await relink;
          expect(await later, isTrue);
          final disk = const ProjectPackageCodec().decode(
            await File('${f.data.path}/projects/A.json').readAsString(),
          );
          expect(f.state.project.candidates.single.note, 'after');
          expect(disk.candidates.single.note, 'after');
          expect(f.state.canUndoReview, isTrue);
          await f.state.undoReview();
          expect(f.state.project.candidates.single.note, 'before');
          expect(f.state.canUndoReview, outcome != 'success');
          if (outcome == 'success') {
            expect(
              f.state.project.video!.path,
              contains('/videos/A/source.mp4'),
            );
          } else {
            expect(f.state.project.video!.path, '${f.root.path}/missing.mp4');
            expect(
              await File('${f.data.path}/videos/A/source.mp4').exists(),
              isFalse,
            );
          }
          if (outcome == 'failure') expect(f.state.diagnosticError, isNotNull);
        } finally {
          await f.close();
        }
      },
    );
  }
}
