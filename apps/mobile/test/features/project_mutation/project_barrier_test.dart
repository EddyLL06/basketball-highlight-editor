import 'dart:async';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'failed note followed by addPlayer never writes the failed note',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        f.state.project = f.project('${f.root.path}/missing.mp4');
        expect(await f.state.updateCandidateNote('goal', 'A'), isTrue);
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
                  throw PlatformException(code: 'failed_note');
                }
                return f.root.path;
              },
            );
        final failed = f.state.updateCandidateNote('goal', 'B');
        await entered.future;
        final add = f.state.addPlayer('Carol');
        release.complete();
        expect(await failed, isFalse);
        expect(await add, isTrue);
        final disk = const ProjectPackageCodec().decode(
          await File('${f.data.path}/projects/A.json').readAsString(),
        );
        expect(f.state.project.candidates.single.note, 'A');
        expect(disk.candidates.single.note, 'A');
        expect(disk.players, ['Alice', 'Carol']);
        expect(f.state.project.players, disk.players);
      } finally {
        await f.close();
      }
    },
  );

  for (final operation in ['new', 'open', 'delete', 'import']) {
    test(
      '$operation is a barrier for pending writes and later clicks',
      () async {
        final f = MobileVideoFixture();
        await f.init();
        try {
          f.state.project = f
              .project('${f.root.path}/missing.mp4')
              .copyWith(clearVideo: true);
          expect(await f.state.updateCandidateNote('goal', 'A'), isTrue);
          if (operation == 'import') {
            final imported = await f.file(
              'import.json',
              const ProjectPackageCodec().encode(
                f.project('missing').copyWith(id: 'B', clearVideo: true),
              ),
            );
            f.choose(imported);
          }
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
                  return f.root.path;
                },
              );
          final pending = f.state.updateCandidateNote('goal', 'before switch');
          await entered.future;
          var finished = false;
          final transition = switch (operation) {
            'new' => f.state.createNewProject(),
            'open' => f.state.openProject('A'),
            'delete' => f.state.clearProject(),
            _ => f.state.importProject(),
          };
          transition.then((_) => finished = true);
          for (var i = 0; i < 100 && !f.state.projectTransitioning; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(f.state.projectTransitioning, isTrue);
          expect(finished, isFalse);
          expect(
            await f.state.updateCandidateNote('goal', 'during switch'),
            isFalse,
          );
          release.complete();
          expect(await pending, isTrue);
          await transition;
          await f.state.pendingProjectWrites;
          if (operation == 'delete') {
            expect(
              await File('${f.data.path}/projects/A.json').exists(),
              isFalse,
            );
          } else {
            final old = const ProjectPackageCodec().decode(
              await File('${f.data.path}/projects/A.json').readAsString(),
            );
            expect(old.candidates.single.note, 'before switch');
            if (operation == 'open') {
              expect(f.state.project.id, 'A');
              expect(f.state.project.candidates.single.note, 'before switch');
            } else {
              expect(f.state.project.id, isNot('A'));
            }
          }
        } finally {
          await f.close();
        }
      },
    );
  }

  test(
    'queued settings use explicit field intent even when values return to the original',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        f.state.project = f.project('${f.root.path}/missing.mp4');
        final initial = f.state.project.settings;
        final first = f.state.updateSettings(
          initial.copyWith(startMs: 100),
          fields: {'startMs'},
        );
        final second = f.state.updateSettings(
          initial.copyWith(startMs: 0),
          fields: {'startMs'},
        );
        final third = f.state.updateSettings(
          initial.copyWith(sampleFps: 5),
          fields: {'sampleFps'},
        );
        expect(await Future.wait([first, second, third]), everyElement(isTrue));
        expect(f.state.project.settings.startMs, 0);
        expect(f.state.project.settings.sampleFps, 5);
        final disk = const ProjectPackageCodec().decode(
          await File('${f.data.path}/projects/A.json').readAsString(),
        );
        expect(disk.settings.startMs, 0);
        expect(disk.settings.sampleFps, 5);
      } finally {
        await f.close();
      }
    },
  );

  test(
    'pending player rename and later add keep both changes on disk and in memory',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        f.state.project = f.project('${f.root.path}/missing.mp4');
        expect(await f.state.updateCandidateNote('goal', 'baseline'), isTrue);
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
                return f.root.path;
              },
            );
        final rename = f.state.renamePlayer('Alice', 'Bob');
        await entered.future;
        final add = f.state.addPlayer('Carol');
        release.complete();
        expect(await rename, isTrue);
        expect(await add, isTrue);
        final disk = const ProjectPackageCodec().decode(
          await File('${f.data.path}/projects/A.json').readAsString(),
        );
        expect(f.state.project.players, ['Bob', 'Carol']);
        expect(disk.players, ['Bob', 'Carol']);
        expect(f.state.recentProjects.first.players, ['Bob', 'Carol']);
        expect(disk.candidates.single.player, 'Bob');
        expect(f.state.canUndoReview, isTrue);
      } finally {
        await f.close();
      }
    },
  );

  test(
    'selecting an existing player does not perform an unnecessary write',
    () async {
      final f = MobileVideoFixture();
      await f.init();
      try {
        f.state.project = f.project('${f.root.path}/missing.mp4');
        var called = false;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async {
                called = true;
                throw PlatformException(code: 'should_not_write');
              },
            );
        expect(await f.state.addPlayer('Alice'), isTrue);
        expect(called, isFalse);
        expect(f.state.diagnosticError, isNull);
      } finally {
        await f.close();
      }
    },
  );
}
