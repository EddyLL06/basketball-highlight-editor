import 'dart:async';
import 'dart:io';
import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'failed project rename cannot be resurrected by queued note save',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        final file = await f.file('original.mp4', 'original');
        f.state.project = f.project(file.path);
        f.state.recentProjects = [f.state.project];
        expect(await f.state.renameProject('Initial'), isTrue);
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
                  throw PlatformException(code: 'injected_failure');
                }
                return f.root.path;
              },
            );
        final rename = f.state.renameProject('New');
        await entered.future;
        final note = f.state.updateCandidateNote('goal', 'later');
        release.complete();
        expect(await rename, isFalse);
        expect(await note, isTrue);
        final disk = const ProjectPackageCodec().decode(
          await File('${f.data.path}/projects/A.json').readAsString(),
        );
        expect(f.state.project.name, 'Initial');
        expect(f.state.recentProjects.first.name, 'Initial');
        expect(disk.name, 'Initial');
        expect(disk.candidates.single.note, 'later');
        expect(f.state.diagnosticError, isNotNull);
      } finally {
        await f.close();
      }
    },
  );
  for (final delete in [false, true]) {
    test(
      'failed player ${delete ? 'deletion' : 'rename'} preserves project and history',
      () async {
        final f = MobileVideoFixture();
        await f.init();
        try {
          final file = await f.file('original.mp4', 'original');
          f.state.project = f.project(file.path);
          await f.state.setCandidatePlayer('goal', null);
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
                    throw PlatformException(code: 'injected_failure');
                  }
                  return f.root.path;
                },
              );
          final update = delete
              ? f.state.removePlayer('Alice')
              : f.state.renamePlayer('Alice', 'Carol');
          await entered.future;
          final note = f.state.updateCandidateNote('goal', 'later');
          release.complete();
          expect(await update, isFalse);
          expect(await note, isTrue);
          expect(f.state.project.players, ['Alice']);
          expect(f.state.project.candidates.single.note, 'later');
          expect(f.state.diagnosticError, isNotNull);
          await f.state.undoReview();
          await f.state.undoReview();
          expect(f.state.project.candidates.single.player, 'Alice');
          final disk = const ProjectPackageCodec().decode(
            await File('${f.data.path}/projects/A.json').readAsString(),
          );
          expect(disk.players, ['Alice']);
          expect(disk.candidates.single.player, 'Alice');
        } finally {
          await f.close();
        }
      },
    );
  }
}
