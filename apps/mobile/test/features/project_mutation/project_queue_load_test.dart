import 'dart:async';
import 'dart:io';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/review_undo/review_action_result.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'slow storage retains 30 review intents and separate undo steps',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        f.state.project = f
            .project('${f.root.path}/missing.mp4')
            .copyWith(
              candidates: [
                for (var i = 0; i < 30; i++)
                  Candidate(
                    id: '$i',
                    startMs: i * 1000,
                    endMs: (i + 1) * 1000,
                    eventMs: i * 1000 + 500,
                  ),
              ],
            );
        final entered = Completer<void>(), release = Completer<void>();
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
                await Future<void>.delayed(const Duration(milliseconds: 15));
                return f.root.path;
              },
            );
        final clock = Stopwatch()..start();
        final writes = [
          f.state.toggleCandidate('0', CandidateSelection.excluded),
        ];
        await entered.future;
        for (var i = 1; i < 30; i++) {
          writes.add(
            f.state.toggleCandidate('$i', CandidateSelection.excluded),
          );
        }
        final peak = f.state.pendingProjectMutations;
        expect(peak, 30);
        release.complete();
        expect(
          await Future.wait(writes),
          everyElement(ReviewActionResult.changed),
        );
        clock.stop();
        expect(f.state.pendingProjectMutations, 0);
        final disk = const ProjectPackageCodec().decode(
          await File('${f.data.path}/projects/A.json').readAsString(),
        );
        expect(
          disk.candidates
              .where((c) => c.selection == CandidateSelection.excluded)
              .length,
          30,
        );
        await f.state.undoReview();
        expect(
          f.state.project.candidates[29].selection,
          CandidateSelection.included,
        );
        expect(
          f.state.project.candidates[28].selection,
          CandidateSelection.excluded,
        );
        debugPrint(
          '30 queued reviews: peak=$peak, tail=${clock.elapsedMilliseconds}ms, path-provider delay=15ms',
        );
      } finally {
        await f.close();
      }
    },
  );
}
