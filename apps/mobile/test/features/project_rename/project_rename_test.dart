import 'dart:io';
import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'validates visible characters and updates recent list immediately and on disk',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        final source = await f.file('original.mp4', 'original');
        f.state.project = f.project(source.path);
        f.state.recentProjects = [f.state.project];
        expect(await f.state.renameProject('  '), isFalse);
        expect(await f.state.renameProject('x' * 41), isFalse);
        final value = '👨‍👩‍👧‍👦' * 40;
        final operation = f.state.renameProject(' $value ');
        await Future<void>.delayed(Duration.zero);
        expect(f.state.project.name, value);
        expect(f.state.recentProjects.single.name, value);
        expect(await operation, isTrue);
        expect(f.state.project.id, 'A');
        expect(f.state.project.video!.path, source.path);
        final saved = const ProjectPackageCodec().decode(
          await File('${f.data.path}/projects/A.json').readAsString(),
        );
        expect(saved.name, value);
        await f.state.openProject('A');
        expect(f.state.recentProjects.first.name, value);
      } finally {
        await f.close();
      }
    },
  );
  test('failed save rolls the name back', () async {
    final f = MobileVideoFixture();
    await f.init();
    try {
      final source = await f.file('original.mp4', 'original');
      f.state.project = f.project(source.path);
      f.state.recentProjects = [f.state.project];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => throw PlatformException(code: 'unavailable'),
          );
      expect(await f.state.renameProject('New name'), isFalse);
      expect(f.state.project.name, 'A');
      expect(f.state.recentProjects.single.name, 'A');
    } finally {
      await f.close();
    }
  });
}
