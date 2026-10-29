import 'dart:async';
import 'dart:io';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/native_analysis_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('com.bhe.bhe/mobile_analysis');
  const event = MethodChannel('com.bhe.bhe/mobile_analysis_progress');
  late MobileVideoFixture f;
  setUp(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(event, (_) async => null),
  );
  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(method, null);
    messenger.setMockMethodCallHandler(event, null);
    await f.close();
  });
  Future<void> progress() async {
    final data = const StandardMethodCodec().encodeSuccessEnvelope({
      'stage': 'refineCandidates',
      'progress': 0.4,
      'message': 'native progress',
    });
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(event.name, data, (_) {});
    await pumpEventQueue();
  }

  for (final isProgress in [true, false]) {
    for (final fail in [true, false]) {
      test(
        '${isProgress ? 'progress' : 'result'} before cancel ${fail ? 'failure' : 'success'}',
        () async {
          final started = Completer<void>(), result = Completer<Object?>();
          final cancelling = Completer<void>(), response = Completer<void>();
          var starts = 0, cancels = 0;
          f = MobileVideoFixture();
          await f.init(
            engine: NativeAnalysisEngine(modelPreparer: () async => '/model'),
          );
          final file = await f.file('original.mp4', 'original');
          f.state.project = f.project(file.path);
          expect(await f.state.updateCandidateNote('goal', 'keep'), isTrue);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(method, (call) async {
                if (call.method == 'analyzeVideo') {
                  starts++;
                  started.complete();
                  return result.future;
                }
                if (call.method == 'cancelAnalysis') {
                  cancels++;
                  cancelling.complete();
                  await response.future;
                  if (fail) throw PlatformException(code: 'CANCEL_FAIL');
                }
                return null;
              });
          final analysis = f.state.startAnalysis();
          await started.future;
          final cancel = f.state.cancelAnalysis();
          await cancelling.future;
          final duplicate = f.state.cancelAnalysis();
          await f.state.startAnalysis();
          expect(starts, 1);
          if (isProgress) {
            await progress();
          } else {
            result.complete({'candidates': <Object>[]});
            await pumpEventQueue();
          }
          expect(f.state.analysing, isTrue);
          expect(f.state.project.candidates.single.note, 'keep');
          expect(f.state.canUndoReview, isTrue);
          response.complete();
          await Future.wait([cancel, duplicate]);
          expect(cancels, 1);
          if (isProgress) result.complete({'candidates': <Object>[]});
          await analysis;
          final disk = const ProjectPackageCodec().decode(
            await File('${f.data.path}/projects/A.json').readAsString(),
          );
          if (fail) {
            expect(f.state.diagnosticError, isNotNull);
            expect(f.state.stage, AnalysisStage.completed);
            expect(disk.lastAnalysisStatus, 'completed');
          } else {
            expect(f.state.stage, AnalysisStage.cancelled);
            expect(disk.candidates.single.note, 'keep');
            expect(f.state.canUndoReview, isTrue);
          }
          expect(f.state.analysing, isFalse);
        },
      );
    }
  }
  test(
    'startup timeout preserves reviews, stops waiting and blocks retry until result',
    () async {
      final started = Completer<void>(), result = Completer<Object?>();
      var starts = 0, cancels = 0;
      f = MobileVideoFixture();
      await f.init(
        engine: NativeAnalysisEngine(
          modelPreparer: () async => '/model',
          cancelTimeout: const Duration(milliseconds: 30),
        ),
        analysisStartupTimeout: const Duration(milliseconds: 40),
        analysisCancelTimeout: const Duration(milliseconds: 60),
      );
      final file = await f.file('original.mp4', 'original');
      f.state.project = f.project(file.path);
      expect(await f.state.updateCandidateNote('goal', 'keep'), isTrue);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(method, (call) async {
            if (call.method == 'analyzeVideo') {
              starts++;
              started.complete();
              return result.future;
            }
            if (call.method == 'cancelAnalysis') {
              cancels++;
              throw PlatformException(code: 'CANCEL_FAIL');
            }
            if (call.method == 'isAnalysisActive') return false;
            return null;
          });
      final analysis = f.state.startAnalysis();
      await started.future;
      await analysis.timeout(const Duration(seconds: 2));
      expect(f.state.analysing, isFalse);
      expect(f.state.diagnosticError, isNotNull);
      expect(f.state.project.candidates.single.note, 'keep');
      expect(f.state.canUndoReview, isTrue);
      await f.state.startAnalysis();
      expect(starts, 1);
      expect(cancels, 1);
      result.complete({'candidates': <Object>[]});
      await pumpEventQueue();
      expect(f.state.canStartAnalysis, isTrue);
    },
  );
  test(
    'stalled cancel returns with diagnostic and keeps old reviews',
    () async {
      final started = Completer<void>(),
          result = Completer<Object?>(),
          cancelResult = Completer<void>();
      var cancels = 0;
      f = MobileVideoFixture();
      await f.init(
        engine: NativeAnalysisEngine(
          modelPreparer: () async => '/model',
          cancelTimeout: const Duration(milliseconds: 30),
        ),
        analysisStartupTimeout: const Duration(seconds: 2),
        analysisCancelTimeout: const Duration(milliseconds: 60),
      );
      final file = await f.file('original.mp4', 'original');
      f.state.project = f.project(file.path);
      expect(await f.state.updateCandidateNote('goal', 'keep'), isTrue);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(method, (call) async {
            if (call.method == 'analyzeVideo') {
              started.complete();
              return result.future;
            }
            if (call.method == 'cancelAnalysis') {
              cancels++;
              await cancelResult.future;
              return null;
            }
            return null;
          });
      final analysis = f.state.startAnalysis();
      await started.future;
      await f.state.cancelAnalysis().timeout(const Duration(seconds: 2));
      await analysis.timeout(const Duration(seconds: 2));
      expect(cancels, 1);
      expect(f.state.analysing, isFalse);
      expect(f.state.diagnosticError, isNotNull);
      expect(f.state.project.candidates.single.note, 'keep');
      expect(f.state.canUndoReview, isTrue);
      expect(f.state.canStartAnalysis, isFalse);
      result.complete({'candidates': <Object>[]});
      cancelResult.complete();
      await pumpEventQueue();
    },
  );
  test(
    'switch while cancel fails does not write the old result to either project',
    () async {
      final started = Completer<void>(), result = Completer<Object?>();
      final cancelling = Completer<void>(), response = Completer<void>();
      var calls = 0;
      f = MobileVideoFixture();
      await f.init(
        engine: NativeAnalysisEngine(modelPreparer: () async => '/model'),
      );
      final file = await f.file('original.mp4', 'original');
      f.state.project = f.project(file.path);
      expect(await f.state.updateCandidateNote('goal', 'keep'), isTrue);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(method, (call) async {
            if (call.method == 'analyzeVideo') {
              started.complete();
              return result.future;
            }
            if (call.method == 'cancelAnalysis') {
              if (++calls == 1) {
                cancelling.complete();
                await response.future;
                throw PlatformException(code: 'CANCEL_FAIL');
              }
            }
            return null;
          });
      final analysis = f.state.startAnalysis();
      await started.future;
      final cancel = f.state.cancelAnalysis();
      await cancelling.future;
      final switchProject = f.state.createNewProject();
      await progress();
      response.complete();
      await cancel;
      await switchProject;
      final newId = f.state.project.id;
      expect(newId, isNot('A'));
      result.complete({'candidates': <Object>[]});
      await analysis;
      final disk = const ProjectPackageCodec().decode(
        await File('${f.data.path}/projects/A.json').readAsString(),
      );
      expect(disk.candidates.single.note, 'keep');
      expect(f.state.project.id, newId);
      expect(f.state.project.lastAnalysisStatus, isNull);
    },
  );
}
