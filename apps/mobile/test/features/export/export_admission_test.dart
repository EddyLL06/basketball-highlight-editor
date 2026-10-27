import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.bhe.bhe/mobile_media');
  late MobileVideoFixture f;
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await f.close();
  });
  for (final mixed in [false, true]) {
    test(
      'preflight excludes ${mixed ? 'separate export' : 'second merge'}',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        f = MobileVideoFixture();
        await f.init(
          probe: (file) async {
            if (!entered.isCompleted) entered.complete();
            await release.future;
            return MobileVideoFixture.inspect(file);
          },
        );
        final file = await f.file('original.mp4', 'original');
        f.state.project = f.project(file.path);
        var merges = 0, clips = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'mergeClips') {
                merges++;
                return {'outputPath': 'out.mp4', 'committed': true};
              }
              if (call.method == 'exportClip') clips++;
              return null;
            });
        f.state.progress = .9;
        f.state.progressMessage = 'OLD PROGRESS';
        final first = f.state.mergeClips();
        expect(f.state.progress, 0);
        expect(f.state.progressMessage, '正在检查视频');
        await entered.future;
        expect(f.state.exporting, isTrue);
        await (mixed ? f.state.exportClips() : f.state.mergeClips());
        release.complete();
        await first;
        expect(merges, 1);
        expect(clips, 0);
        expect(f.state.exporting, isFalse);
      },
    );
  }
  test('cancelled preflight cannot start or cancel the next run', () async {
    final entered = Completer<void>(), release = Completer<void>();
    var probes = 0, merges = 0, cancels = 0;
    f = MobileVideoFixture();
    await f.init(
      probe: (file) async {
        if (++probes == 1) {
          entered.complete();
          await release.future;
        }
        return MobileVideoFixture.inspect(file);
      },
    );
    final file = await f.file('original.mp4', 'original');
    f.state.project = f.project(file.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'cancelExport') cancels++;
          if (call.method == 'mergeClips') {
            merges++;
            return {'outputPath': 'out.mp4', 'committed': true};
          }
          return null;
        });
    final old = f.state.mergeClips();
    await entered.future;
    await f.state.cancelExport();
    expect(f.state.exporting, isFalse);
    await f.state.mergeClips();
    release.complete();
    await old;
    expect(merges, 1);
    expect(cancels, 0);
    expect(f.state.exportCancelled, isFalse);
  });
  test('failed preflight releases admission for retry', () async {
    var probes = 0, merges = 0;
    f = MobileVideoFixture();
    await f.init(
      probe: (file) async {
        if (++probes == 1) throw StateError('probe failed');
        return MobileVideoFixture.inspect(file);
      },
    );
    final file = await f.file('original.mp4', 'original');
    f.state.project = f.project(file.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'mergeClips') {
            merges++;
            return {'outputPath': 'out.mp4', 'committed': true};
          }
          return null;
        });
    await f.state.mergeClips();
    expect(f.state.exporting, isFalse);
    await f.state.mergeClips();
    expect(merges, 1);
  });
  test(
    'running task excludes retries and cancellation targets its ID',
    () async {
      f = MobileVideoFixture();
      await f.init();
      final file = await f.file('original.mp4', 'original');
      f.state.project = f.project(file.path);
      final entered = Completer<void>(), finish = Completer<Object?>();
      var calls = 0;
      String? registered, cancelled;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'registerMergeExport') {
              registered = (call.arguments as Map)['exportId'] as String;
              return true;
            }
            if (call.method == 'mergeClips') {
              calls++;
              entered.complete();
              return finish.future;
            }
            if (call.method == 'cancelExport') {
              cancelled = (call.arguments as Map)['exportId'] as String;
            }
            return null;
          });
      final pending = f.state.mergeClips();
      await entered.future;
      await f.state.mergeClips();
      await f.state.exportClips();
      expect(calls, 1);
      await f.state.cancelExport();
      expect(cancelled, registered);
      await f.state.mergeClips();
      expect(calls, 1);
      finish.completeError(PlatformException(code: 'EXPORT_CANCELLED'));
      await pending;
      expect(f.state.exporting, isFalse);
    },
  );
  test(
    'project switch cancels old task without cancelling a new one',
    () async {
      f = MobileVideoFixture();
      await f.init();
      final file = await f.file('original.mp4', 'original');
      f.state.project = f.project(file.path);
      final entered = Completer<void>(), finishOld = Completer<Object?>();
      final ids = <String>[], cancellations = <String>[];
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'registerMergeExport') {
              ids.add((call.arguments as Map)['exportId'] as String);
              return true;
            }
            if (call.method == 'cancelExport') {
              cancellations.add((call.arguments as Map)['exportId'] as String);
            }
            if (call.method == 'mergeClips') {
              if (++calls == 1) {
                entered.complete();
                return finishOld.future;
              }
              return {'outputPath': 'new.mp4', 'committed': true};
            }
            return null;
          });
      final old = f.state.mergeClips();
      await entered.future;
      await f.state.createNewProject();
      f.state.project = f.project(file.path, id: 'B');
      final next = f.state.mergeClips();
      await pumpEventQueue();
      expect(calls, 1);
      finishOld.completeError(PlatformException(code: 'EXPORT_CANCELLED'));
      await old;
      await next;
      expect(calls, 2);
      expect(cancellations, [ids.first]);
      expect(ids.first, isNot(ids.last));
      expect(f.state.exportedPaths, ['new.mp4']);
      expect(f.state.exportCancelled, isFalse);
    },
  );
}
