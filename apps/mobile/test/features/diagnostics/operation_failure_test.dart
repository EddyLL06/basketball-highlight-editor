import 'dart:async';
import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/mobile_video_fixture.dart';

class FailingCancellation extends MobileAnalysisEngineUnavailable {
  final started = Completer<void>();
  final results = StreamController<AnalysisProgress>();
  @override
  Stream<AnalysisProgress> analyze({
    required VideoInfo video,
    required Roi hoopRoi,
    Roi? rimRoi,
    required Roi netRoi,
    required AnalysisSettings settings,
  }) {
    started.complete();
    return results.stream;
  }

  @override
  Future<void> cancel() async => throw PlatformException(
    code: 'CANCEL_FAILED',
    message: 'TECHNICAL /private/person/video.mp4',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'failed native cancellation leaves completion able to clear busy state',
    () async {
      final fixture = MobileVideoFixture();
      final engine = FailingCancellation();
      await fixture.init(engine: engine);
      try {
        final source = await fixture.file('original.mp4', 'original');
        fixture.state.project = fixture.project(source.path);
        final analysis = fixture.state.startAnalysis();
        await engine.started.future;
        await fixture.state.cancelAnalysis();
        expect(fixture.state.diagnosticError?.error, isA<PlatformException>());
        expect(fixture.state.errorMessage, '出错了：视频分析未完成，请重试。');
        expect(fixture.state.analysing, isTrue);
        engine.results.add(
          const AnalysisProgress(
            stage: AnalysisStage.completed,
            progress: 1,
            message: '分析完成',
          ),
        );
        await engine.results.close();
        await analysis;
        expect(fixture.state.analysing, isFalse);
        expect(fixture.state.stage, AnalysisStage.completed);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'share plugin failures are retained and shown as safe export errors',
    () async {
      final fixture = MobileVideoFixture();
      await fixture.init();
      const channel = MethodChannel('dev.fluttercommunity.plus/share');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(
          code: 'SHARE_FAILED',
          message: 'TECHNICAL /private/person/goal.mp4',
        ),
      );
      try {
        fixture.state.exportedPaths = ['not-read.mp4'];
        await fixture.state.shareExportedFiles();
        expect(fixture.state.diagnosticError?.error, isA<PlatformException>());
        expect(fixture.state.errorMessage, '出错了：视频导出未完成，请重试。');
        expect(fixture.state.exporting, isFalse);
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        await fixture.close();
      }
    },
  );
}
