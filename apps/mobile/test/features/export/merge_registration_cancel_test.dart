import 'dart:async';
import 'dart:io';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/media_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.bhe.bhe/mobile_media');
  const video = VideoInfo(
    path: 'source.mp4',
    name: 'source',
    sizeBytes: 1,
    durationMs: 10000,
    width: 100,
    height: 100,
  );
  const clips = [Candidate(id: 'c', startMs: 0, endMs: 1000, eventMs: 500)];
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  test(
    'cancel while preparation progress is visible does not start native merge',
    () async {
      final flags = <String, bool>{};
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = call.arguments as Map?;
            final id = args?['exportId'] as String?;
            switch (call.method) {
              case 'registerMergeExport':
                flags[id!] = false;
                return true;
              case 'cancelExport':
                flags[id!] = true;
                return null;
              case 'releaseMergeExport':
                flags.remove(id);
                return null;
              case 'mergeClips':
                calls++;
                return {'committed': true, 'outputPath': 'out.mp4'};
            }
            return null;
          });
      final engine = NativeMediaExportEngine();
      final iterator = StreamIterator(
        engine.mergeClips(
          video: video,
          candidates: clips,
          outputPath: 'out.mp4',
        ),
      );
      expect(await iterator.moveNext(), isTrue);
      await engine.cancel();
      await expectLater(
        iterator.moveNext(),
        throwsA(isA<MobileExportException>()),
      );
      expect(calls, 0);
      expect(flags, isEmpty);
      await iterator.cancel();
    },
  );
  test(
    'cancel during registration binds to same task and leaves old file',
    () async {
      final root = await Directory.systemTemp.createTemp('merge-registration-');
      final old = File('${root.path}/out.mp4')..writeAsStringSync('old');
      final flags = <String, bool>{};
      final entered = Completer<void>(), release = Completer<void>();
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = call.arguments as Map?;
            final id = args?['exportId'] as String?;
            switch (call.method) {
              case 'registerMergeExport':
                flags[id!] = false;
                entered.complete();
                await release.future;
                return true;
              case 'cancelExport':
                flags[id!] = true;
                return null;
              case 'releaseMergeExport':
                flags.remove(id);
                return null;
              case 'mergeClips':
                calls++;
                await old.writeAsString('replaced');
                return {'committed': true};
            }
            return null;
          });
      try {
        final engine = NativeMediaExportEngine();
        final iterator = StreamIterator(
          engine.mergeClips(
            video: video,
            candidates: clips,
            outputPath: old.path,
          ),
        );
        final next = iterator.moveNext();
        await entered.future;
        await engine.cancel();
        release.complete();
        await expectLater(next, throwsA(isA<MobileExportException>()));
        expect(calls, 0);
        expect(await old.readAsString(), 'old');
        expect(flags, isEmpty);
        await iterator.cancel();
      } finally {
        if (!release.isCompleted) release.complete();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'cancel after request dispatch uses reservation before native task starts',
    () async {
      final root = await Directory.systemTemp.createTemp('merge-dispatch-');
      final old = File('${root.path}/out.mp4')..writeAsStringSync('old');
      final flags = <String, bool>{};
      final entered = Completer<void>(), release = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = call.arguments as Map?;
            final id = args?['exportId'] as String?;
            switch (call.method) {
              case 'registerMergeExport':
                flags[id!] = false;
                return true;
              case 'cancelExport':
                flags[id!] = true;
                return null;
              case 'releaseMergeExport':
                flags.remove(id);
                return null;
              case 'mergeClips':
                expect(args!['reservationRequired'], isTrue);
                entered.complete();
                await release.future;
                if (flags[id] == true) {
                  throw PlatformException(code: 'EXPORT_CANCELLED');
                }
                await old.writeAsString('replaced');
                return {'committed': true};
            }
            return null;
          });
      try {
        final engine = NativeMediaExportEngine();
        final future = engine
            .mergeClips(video: video, candidates: clips, outputPath: old.path)
            .toList();
        await entered.future;
        await engine.cancel();
        release.complete();
        await expectLater(future, throwsA(isA<Exception>()));
        expect(await old.readAsString(), 'old');
        expect(flags, isEmpty);
      } finally {
        if (!release.isCompleted) release.complete();
        await root.delete(recursive: true);
      }
    },
  );
}
