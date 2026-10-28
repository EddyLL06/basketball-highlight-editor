import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cancelled old native merge must drain before new project merge begins',
    () async {
      final f = MobileVideoFixture();
      const channel = MethodChannel('com.bhe.bhe/mobile_media');
      await f.init();
      final entered = Completer<void>(), finish = Completer<Object?>();
      var active = 0, maxActive = 0, calls = 0;
      final ids = <String>[], cancels = <String?>[], paths = <String>[];
      try {
        final video = await f.file('original.mp4', 'original');
        f.state.project = f.project(video.path);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'registerMergeExport') {
                ids.add((call.arguments as Map)['exportId'] as String);
                return true;
              }
              if (call.method == 'cancelExport') {
                cancels.add((call.arguments as Map?)?['exportId'] as String?);
                return null;
              }
              if (call.method == 'mergeClips') {
                calls++;
                active++;
                if (active > maxActive) maxActive = active;
                paths.add((call.arguments as Map)['outputPath'] as String);
                if (calls == 1) {
                  entered.complete();
                  try {
                    return await finish.future;
                  } finally {
                    active--;
                  }
                }
                active--;
                return {
                  'outputPath': (call.arguments as Map)['outputPath'],
                  'committed': true,
                };
              }
              return null;
            });
        final old = f.state.mergeClips();
        await entered.future.timeout(const Duration(seconds: 5));
        await f.state.createNewProject();
        f.state.project = f.project(video.path, id: 'B');
        final next = f.state.mergeClips();
        for (
          var attempt = 0;
          attempt < 100 && f.state.progressMessage != '正在结束上一次导出';
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(calls, 1);
        expect(f.state.progressMessage, '正在结束上一次导出');
        finish.completeError(PlatformException(code: 'EXPORT_CANCELLED'));
        await old;
        await next.timeout(const Duration(seconds: 5));
        await f.state.pendingProjectWrites;
        expect(calls, 2);
        expect(cancels, [ids.first]);
        expect(ids.first, isNot(ids.last));
        expect(f.state.exportedPaths.single, paths.last);
        expect(
          maxActive,
          1,
          reason: 'A cancelled native merge remains active while B starts',
        );
      } finally {
        if (!finish.isCompleted) {
          finish.completeError(PlatformException(code: 'EXPORT_CANCELLED'));
        }
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await f.close();
      }
    },
  );
}
