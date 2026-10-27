import 'dart:async';
import 'dart:io';
import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/native_analysis_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/mobile_video_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.bhe.bhe/mobile_analysis');
  const events = MethodChannel('com.bhe.bhe/mobile_analysis_progress');
  late MobileVideoFixture f;
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(events, (_) async => null);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(events, null);
    await f.close();
  });

  test(
    'cancel during model preparation preserves reviews on disk and undo',
    () async {
      final entered = Completer<void>(), model = Completer<String>();
      var starts = 0, cancels = 0;
      final engine = NativeAnalysisEngine(
        modelPreparer: () {
          entered.complete();
          return model.future;
        },
      );
      f = MobileVideoFixture();
      await f.init(engine: engine);
      final file = await f.file('original.mp4', 'original');
      f.state.project = f.project(file.path);
      expect(await f.state.updateCandidateNote('goal', 'keep'), isTrue);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'analyzeVideo') starts++;
            if (call.method == 'cancelAnalysis') cancels++;
            return null;
          });
      final pending = f.state.startAnalysis(rosterPlayers: ['Bob']);
      await entered.future;
      await f.state.cancelAnalysis();
      model.complete('/model');
      await pending;
      final disk = const ProjectPackageCodec().decode(
        await File('${f.data.path}/projects/A.json').readAsString(),
      );
      expect(starts, 0);
      expect(cancels, 0);
      expect(f.state.project.candidates.single.note, 'keep');
      expect(disk.candidates.single.note, 'keep');
      expect(f.state.canUndoReview, isTrue);
      expect(disk.players, contains('Bob'));
    },
  );

  test(
    'retry has its own token and old preparation cannot start late',
    () async {
      final firstEntered = Completer<void>(),
          first = Completer<String>(),
          secondEntered = Completer<void>();
      var preparations = 0, starts = 0;
      final engine = NativeAnalysisEngine(
        modelPreparer: () {
          if (++preparations == 1) {
            firstEntered.complete();
            return first.future;
          }
          secondEntered.complete();
          return Future.value('/model');
        },
      );
      f = MobileVideoFixture();
      await f.init(engine: engine);
      final file = await f.file('original.mp4', 'original');
      f.state.project = f.project(file.path);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'analyzeVideo') {
              starts++;
              return {'candidates': <Object>[]};
            }
            return null;
          });
      final old = f.state.startAnalysis();
      await firstEntered.future;
      await f.state.cancelAnalysis();
      final retry = f.state.startAnalysis();
      await secondEntered.future;
      await retry;
      first.complete('/old');
      await old;
      expect(starts, 1);
      expect(f.state.stage, AnalysisStage.completed);
    },
  );

  for (final fail in [false, true]) {
    test(
      'cancel next to native dispatch ${fail ? 'failure is reported' : 'targets started task'}',
      () async {
        final entered = Completer<void>(), result = Completer<Object?>();
        var cancels = 0;
        final engine = NativeAnalysisEngine(
          modelPreparer: () async => '/model',
        );
        f = MobileVideoFixture();
        await f.init(engine: engine);
        final file = await f.file('original.mp4', 'original');
        f.state.project = f.project(file.path);
        expect(await f.state.updateCandidateNote('goal', 'keep'), isTrue);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'analyzeVideo') {
                entered.complete();
                return result.future;
              }
              if (call.method == 'cancelAnalysis') {
                cancels++;
                if (fail) throw PlatformException(code: 'CANCEL_FAIL');
              }
              return null;
            });
        final pending = f.state.startAnalysis();
        await entered.future;
        await f.state.cancelAnalysis();
        expect(cancels, 1);
        expect(f.state.project.candidates.single.note, 'keep');
        expect(f.state.canUndoReview, isTrue);
        final disk = const ProjectPackageCodec().decode(
          await File('${f.data.path}/projects/A.json').readAsString(),
        );
        expect(disk.candidates.single.note, 'keep');
        if (fail) {
          expect(f.state.analysing, isTrue);
          expect(f.state.diagnosticError, isNotNull);
        }
        result.complete({'candidates': <Object>[]});
        await pending;
        expect(f.state.analysing, isFalse);
        expect(
          f.state.stage,
          fail ? AnalysisStage.completed : AnalysisStage.cancelled,
        );
      },
    );
  }
  test(
    'direct stream cancellation after first event prevents model and native start',
    () async {
      var preparations = 0, starts = 0;
      final engine = NativeAnalysisEngine(
        modelPreparer: () async {
          preparations++;
          return '/model';
        },
      );
      f = MobileVideoFixture();
      await f.init(engine: engine);
      final file = await f.file('original.mp4', 'original');
      final project = f.project(file.path);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'analyzeVideo') starts++;
            return null;
          });
      final iterator = StreamIterator(
        engine.analyze(
          video: project.video!,
          hoopRoi: project.hoopRoi!,
          netRoi: project.netRoi!,
          settings: project.settings,
        ),
      );
      expect(await iterator.moveNext(), isTrue);
      await engine.cancel();
      while (await iterator.moveNext()) {}
      expect(preparations, 0);
      expect(starts, 0);
    },
  );
  test(
    'switch during model preparation preserves old project on disk',
    () async {
      final entered = Completer<void>(), release = Completer<String>();
      var starts = 0;
      final engine = NativeAnalysisEngine(
        modelPreparer: () {
          entered.complete();
          return release.future;
        },
      );
      f = MobileVideoFixture();
      await f.init(engine: engine);
      final file = await f.file('original.mp4', 'original');
      f.state.project = f.project(file.path);
      expect(await f.state.updateCandidateNote('goal', 'keep'), isTrue);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'analyzeVideo') starts++;
            return null;
          });
      final old = f.state.startAnalysis();
      await entered.future;
      await f.state.createNewProject();
      release.complete('/model');
      await old;
      final disk = const ProjectPackageCodec().decode(
        await File('${f.data.path}/projects/A.json').readAsString(),
      );
      expect(disk.candidates.single.note, 'keep');
      expect(starts, 0);
    },
  );
}
