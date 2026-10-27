import 'dart:async';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/video_source/video_source_failure.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MobileVideoFixture fixture;
  setUp(() async {
    fixture = MobileVideoFixture();
    await fixture.init();
  });
  tearDown(() => fixture.close());

  void missing() {
    fixture.state.project = fixture.project('${fixture.root.path}/missing.mp4');
    fixture.state.markVideoFailure(VideoSourceFailure.missing);
  }

  test(
    'successful recovery preserves reviewed clips and clears failure',
    () async {
      missing();
      fixture.choose(await fixture.file('chosen.mp4', 'original'));
      await fixture.state.relinkVideo();
      expect(fixture.state.errorMessage, isNull);
      expect(fixture.state.videoMissing, isFalse);
      expect(fixture.state.relinkingVideo, isFalse);
      expect(fixture.state.project.candidates.single.reviewed, isTrue);
      expect(fixture.state.project.candidates.single.rangeEdited, isTrue);
      expect(
        await File(fixture.state.project.video!.path).readAsString(),
        'original',
      );
    },
  );

  test(
    'mismatch retains metadata and has retry; selecting again succeeds',
    () async {
      missing();
      final before = fixture.state.project;
      fixture.choose(await fixture.file('wrong.mp4', 'different'));
      await fixture.state.relinkVideo();
      expect(fixture.state.project, same(before));
      expect(fixture.state.videoSourceFailure, VideoSourceFailure.mismatch);
      expect(fixture.state.canRelinkVideo, isTrue);
      fixture.choose(await fixture.file('right.mp4', 'original'));
      await fixture.state.relinkVideo();
      expect(fixture.state.errorMessage, isNull);
    },
  );

  test(
    'picker cancellation keeps current fault; channel failure is handled',
    () async {
      missing();
      fixture.choose(null);
      await fixture.state.relinkVideo();
      expect(fixture.state.videoMissing, isTrue);
      fixture.picker.pick = () async =>
          throw PlatformException(code: 'picker_error');
      await fixture.state.relinkVideo();
      expect(fixture.state.videoSourceFailure, VideoSourceFailure.unplayable);
      expect(fixture.state.relinkingVideo, isFalse);
    },
  );

  test(
    'switching during validation cannot write A video or candidates into new B',
    () async {
      await fixture.close();
      fixture = MobileVideoFixture();
      final entered = Completer<void>();
      final release = Completer<void>();
      await fixture.init(
        probe: (file) async {
          entered.complete();
          await release.future;
          return MobileVideoFixture.inspect(file);
        },
      );
      missing();
      var picks = 0;
      final chosen = await fixture.file('picked.mp4', 'original');
      fixture.choose(chosen);
      final originalPick = fixture.picker.pick!;
      fixture.picker.pick = () {
        picks++;
        return originalPick();
      };
      final pending = fixture.state.relinkVideo();
      await entered.future;
      await fixture.state.relinkVideo();
      expect(picks, 1);
      await fixture.state.createNewProject();
      final b = fixture.state.project;
      release.complete();
      await pending;
      expect(fixture.state.project, same(b));
      expect(b.video, isNull);
      expect(b.candidates, isEmpty);
      expect(fixture.state.errorMessage, isNull);
      expect(
        await File('${fixture.data.path}/videos/A/source.mp4').exists(),
        isFalse,
      );
      expect(await chosen.readAsString(), 'original');
    },
  );

  test(
    'explicit cancel during picker keeps original project and ends busy state',
    () async {
      missing();
      final before = fixture.state.project;
      final pick = Completer<Never?>();
      fixture.picker.pick = () => pick.future;
      final pending = fixture.state.relinkVideo();
      fixture.state.cancelVideoRelink();
      expect(fixture.state.relinkCancelling, isTrue);
      pick.complete(null);
      await pending;
      expect(fixture.state.project, same(before));
      expect(fixture.state.relinkingVideo, isFalse);
      expect(fixture.state.videoMissing, isTrue);
    },
  );

  test(
    'opening healthy B resets A fault and unrelated export errors have no relink',
    () async {
      missing();
      final source = await fixture.file(
        'BHE Mobile/videos/B/source.mp4',
        'original',
      );
      final b = fixture.project(source.path, id: 'B');
      await fixture.file(
        'BHE Mobile/projects/B.json',
        const ProjectPackageCodec().encode(b),
      );
      await fixture.state.openProject('B');
      fixture.state.errorMessage = '没有符合条件的保留片段。';
      expect(fixture.state.videoMissing, isFalse);
      expect(fixture.state.canRelinkVideo, isFalse);
    },
  );
}
