import 'dart:convert';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MobileVideoFixture fixture;
  setUp(() async {
    fixture = MobileVideoFixture();
    await fixture.init();
  });
  tearDown(() => fixture.close());

  test(
    'same-device exported BHE package import leaves both project videos intact',
    () async {
      final original = await fixture.file(
        'BHE Mobile/videos/A/source.mp4',
        'original',
      );
      final a = fixture.project(original.path);
      await fixture.file(
        'BHE Mobile/projects/A.json',
        const ProjectPackageCodec().encode(a),
      );
      fixture.state.project = a;
      fixture.state.recentProjects = [a];
      const share = MethodChannel('dev.fluttercommunity.plus/share');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var shared = false;
      messenger.setMockMethodCallHandler(share, (call) async {
        shared = true;
        return 'dev.fluttercommunity.plus/share/success';
      });
      try {
        await fixture.state.exportProjectPackage();
      } finally {
        messenger.setMockMethodCallHandler(share, null);
      }
      expect(shared, isTrue);
      final package = File('${fixture.data.path}/A.bhe');
      expect(await package.exists(), isTrue);
      fixture.choose(package);
      await fixture.state.importProject();
      final b = fixture.state.project;
      expect(b.id, isNot('A'));
      expect(b.video!.path, contains('/videos/${b.id}/source.mp4'));
      expect(await original.readAsString(), 'original');
      expect(await File(b.video!.path).readAsString(), 'original');
      await fixture.state.openProject('A');
      expect(fixture.state.errorMessage, isNull);
      expect(fixture.state.project.candidates.single.reviewed, isTrue);
    },
  );

  test(
    'legacy cached source migrates, survives cache deletion and project reopen',
    () async {
      final cached = await fixture.file(
        'file_picker/old/video.mp4',
        'original',
      );
      final a = fixture.project(cached.path);
      await fixture.file(
        'BHE Mobile/projects/A.json',
        const ProjectPackageCodec().encode(a),
      );
      await fixture.file('BHE Mobile/project_index.json', jsonEncode(['A']));
      await fixture.state.openProject('A');
      final stable = fixture.state.project.video!.path;
      expect(stable, contains('/videos/A/source.mp4'));
      await cached.parent.delete(recursive: true);
      await fixture.state.openProject('A');
      expect(fixture.state.errorMessage, isNull);
      expect(await File(stable).readAsString(), 'original');
      expect(fixture.state.project.candidates.single.rangeEdited, isTrue);
    },
  );

  test(
    'already missing legacy source keeps review and fingerprint for recovery',
    () async {
      final a = fixture.project('${fixture.root.path}/file_picker/gone.mp4');
      await fixture.file(
        'BHE Mobile/projects/A.json',
        const ProjectPackageCodec().encode(a),
      );
      await fixture.state.openProject('A');
      expect(fixture.state.errorMessage, isNotNull);
      expect(fixture.state.project.video!.sha256, 'original');
      expect(fixture.state.project.candidates.single.player, 'Alice');
      expect(fixture.state.project.candidates.single.reviewed, isTrue);
    },
  );
  test(
    'valid recorded cache wins over a stale owned source left by an interrupted import',
    () async {
      await fixture.file('BHE Mobile/videos/A/source.mp4', 'stale partial');
      final cached = await fixture.file(
        'file_picker/old/video.mp4',
        'original',
      );
      final a = fixture.project(cached.path);
      await fixture.file(
        'BHE Mobile/projects/A.json',
        const ProjectPackageCodec().encode(a),
      );
      await fixture.state.openProject('A');
      expect(fixture.state.errorMessage, isNull);
      expect(
        await File(fixture.state.project.video!.path).readAsString(),
        'original',
      );
      expect(fixture.state.project.candidates.single.reviewed, isTrue);
    },
  );
  test(
    'legacy projects sharing a cached path migrate without stealing each other source',
    () async {
      final cached = await fixture.file(
        'file_picker/shared/video.mp4',
        'original',
      );
      final a = fixture.project(cached.path);
      final b = fixture.project(cached.path, id: 'B');
      await fixture.file(
        'BHE Mobile/projects/A.json',
        const ProjectPackageCodec().encode(a),
      );
      await fixture.file(
        'BHE Mobile/projects/B.json',
        const ProjectPackageCodec().encode(b),
      );
      await fixture.state.openProject('A');
      final aPath = fixture.state.project.video!.path;
      expect(await cached.readAsString(), 'original');
      await fixture.state.openProject('B');
      expect(fixture.state.errorMessage, isNull);
      expect(fixture.state.project.video!.path, isNot(aPath));
      expect(await File(aPath).readAsString(), 'original');
      expect(
        await File(fixture.state.project.video!.path).readAsString(),
        'original',
      );
    },
  );
}
