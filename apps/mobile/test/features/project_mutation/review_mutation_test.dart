import 'dart:async';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final sameField in [true, false]) {
    test(
      'failed undo rebases the next ${sameField ? 'same' : 'different'} field',
      () async {
        final f = MobileVideoFixture();
        await f.init();
        try {
          final video = await f.file('original.mp4', 'original');
          f.state.project = f.project(video.path);
          await f.state.updateCandidateNote('goal', 'A');
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
                    throw PlatformException(code: 'injected_failure');
                  }
                  return f.root.path;
                },
              );
          final undo = f.state.undoReview();
          await entered.future;
          final later = sameField
              ? f.state.updateCandidateNote('goal', 'B')
              : f.state.setCandidatePlayer('goal', null);
          release.complete();
          await undo;
          expect(await later, isTrue);
          expect(f.state.diagnosticError, isNotNull);
          await f.state.undoReview();
          expect(f.state.project.candidates.single.note, 'A');
          expect(f.state.project.candidates.single.player, 'Alice');
          final disk = const ProjectPackageCodec().decode(
            await File('${f.data.path}/projects/A.json').readAsString(),
          );
          expect(disk.candidates.single.note, 'A');
          await f.state.undoReview();
          expect(f.state.project.candidates.single.note, isNull);
        } finally {
          await f.close();
        }
      },
    );
  }
}
