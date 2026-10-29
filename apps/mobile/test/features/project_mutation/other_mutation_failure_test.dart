import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final operation in [
    'settings',
    'roi',
    'candidate',
    'player',
    'importPlayers',
    'allCandidates',
  ]) {
    test(
      '$operation failure restores its own fields and reports the error',
      () async {
        final f = MobileVideoFixture();
        await f.init();
        try {
          f.state.project = f.project('${f.root.path}/missing.mp4');
          expect(await f.state.updateCandidateNote('goal', 'baseline'), isTrue);
          final baseline = f.state.project.toJson();
          final projectFile = File('${f.data.path}/projects/A.json');
          final diskBaseline = const ProjectPackageCodec()
              .decode(await projectFile.readAsString())
              .toJson();
          var first = true;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                (_) async {
                  if (first) {
                    first = false;
                    throw PlatformException(code: 'injected_$operation');
                  }
                  return f.root.path;
                },
              );
          final result = switch (operation) {
            'settings' => f.state.updateSettings(
              f.state.project.settings.copyWith(startMs: 123),
            ),
            'roi' => f.state.updateRois(
              hoop: const Roi(left: .1, top: .1, right: .5, bottom: .5),
              net: const Roi(left: .2, top: .2, right: .4, bottom: .4),
            ),
            'candidate' => f.state.addCandidate(
              const Candidate(
                id: 'manual',
                startMs: 0,
                endMs: 500,
                eventMs: 250,
              ),
            ),
            'player' => f.state.addPlayer('Carol'),
            'importPlayers' => f.state.importPlayers(['Carol', 'Drew']),
            _ => f.state.setAllCandidates(CandidateSelection.excluded),
          };
          expect(await result, isFalse);
          expect(f.state.project.toJson(), baseline);
          final saved = const ProjectPackageCodec().decode(
            await projectFile.readAsString(),
          );
          expect(saved.toJson(), diskBaseline);
          expect(f.state.diagnosticError, isNotNull);
        } finally {
          await f.close();
        }
      },
    );
  }
}
