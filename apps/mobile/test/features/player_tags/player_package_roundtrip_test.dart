import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'rename and delete player tags survive real BHE export and import',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      const share = MethodChannel('dev.fluttercommunity.plus/share');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        share,
        (_) async => 'dev.fluttercommunity.plus/share/success',
      );
      try {
        final video = await f.file(
          'BHE Mobile/videos/A/source.mp4',
          'original',
        );
        f.state.project = f
            .project(video.path)
            .copyWith(
              players: ['Alice', 'Drew'],
              candidates: const [
                Candidate(
                  id: 'a',
                  startMs: 1000,
                  endMs: 2000,
                  eventMs: 1500,
                  player: 'Alice',
                  reviewed: true,
                  note: 'kept',
                ),
                Candidate(
                  id: 'b',
                  startMs: 2000,
                  endMs: 3000,
                  eventMs: 2500,
                  player: 'Drew',
                  selection: CandidateSelection.excluded,
                ),
              ],
            );
        expect(await f.state.renamePlayer('Alice', 'Carol'), isTrue);
        expect(await f.state.removePlayer('Drew'), isTrue);
        await f.state.exportProjectPackage();
        final package = File('${f.data.path}/A.bhe');
        expect(await package.exists(), isTrue);
        f.choose(package);
        await f.state.importProject();
        final imported = f.state.project;
        expect(imported.id, isNot('A'));
        expect(imported.players, ['Carol']);
        expect(imported.candidates[0].player, 'Carol');
        expect(imported.candidates[0].note, 'kept');
        expect(imported.candidates[0].reviewed, isTrue);
        expect(imported.candidates[1].player, isNull);
        expect(imported.candidates[1].selection, CandidateSelection.excluded);
        expect(await File(imported.video!.path).readAsString(), 'original');
      } finally {
        messenger.setMockMethodCallHandler(share, null);
        await f.close();
      }
    },
  );
}
