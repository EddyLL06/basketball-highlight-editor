import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mobile_video_fixture.dart';

class RecordingAnalysis extends MobileAnalysisEngineUnavailable {
  int calls = 0;
  @override
  Stream<AnalysisProgress> analyze({
    required VideoInfo video,
    required Roi hoopRoi,
    Roi? rimRoi,
    required Roi netRoi,
    required AnalysisSettings settings,
  }) async* {
    calls++;
    yield const AnalysisProgress(
      stage: AnalysisStage.completed,
      progress: 1,
      message: '分析完成',
      candidates: [Candidate(id: 'new', startMs: 0, endMs: 1000, eventMs: 500)],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final reason in ['missing', 'decode', 'mismatch']) {
    test(
      '$reason validation failure preserves reviewed candidates on disk',
      () async {
        final fixture = MobileVideoFixture();
        final engine = RecordingAnalysis();
        await fixture.init(
          engine: engine,
          probe: reason == 'decode'
              ? (_) async => throw PlatformException(code: 'VideoError')
              : null,
        );
        try {
          final source = await fixture.file(
            'original.mp4',
            reason == 'mismatch' ? 'other' : 'original',
          );
          fixture.state.project = fixture.project(source.path);
          if (reason == 'missing') await source.delete();
          final old = fixture.state.project;
          await fixture.state.startAnalysis();
          expect(engine.calls, 0);
          expect(fixture.state.project.candidates, old.candidates);
          expect(fixture.state.project.players, old.players);
          expect(fixture.state.project.candidates.single.rangeEdited, isTrue);
          expect(fixture.state.project.candidates.single.reviewed, isTrue);
          // Await the same serialized save chain through the existing new-project action.
          await fixture.state.createNewProject();
          final saved = const ProjectPackageCodec().decode(
            await File('${fixture.data.path}/projects/A.json').readAsString(),
          );
          expect(
            ((jsonDecode(
                          await File(
                            '${fixture.data.path}/projects/A.json',
                          ).readAsString(),
                        )
                        as Map)['manifest']['candidates']
                    as List)
                .single,
            old.candidates.single.toJson(),
          );
          expect(saved.players, old.players);
        } finally {
          await fixture.close();
        }
      },
    );
  }

  test(
    'review stays intact during validation, then valid analysis may replace it',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final fixture = MobileVideoFixture();
      final engine = RecordingAnalysis();
      await fixture.init(
        engine: engine,
        probe: (file) async {
          entered.complete();
          await release.future;
          return MobileVideoFixture.inspect(file);
        },
      );
      try {
        final source = await fixture.file('original.mp4', 'original');
        fixture.state.project = fixture.project(source.path);
        final old = fixture.state.project;
        final pending = fixture.state.startAnalysis();
        await entered.future;
        expect(fixture.state.project.candidates, old.candidates);
        expect(engine.calls, 0);
        release.complete();
        await pending;
        expect(engine.calls, 1);
        expect(fixture.state.project.candidates.single.id, 'new');
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'analysis clearing waits for review commit and clears its history',
    () async {
      final fixture = MobileVideoFixture();
      final engine = RecordingAnalysis();
      await fixture.init(engine: engine);
      try {
        final source = await fixture.file('original.mp4', 'original');
        fixture.state.project = fixture.project(source.path);
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
                return fixture.root.path;
              },
            );
        final review = fixture.state.updateCandidateNote('goal', 'in flight');
        await entered.future;
        final analysis = fixture.state.startAnalysis();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(fixture.state.project.candidates.single.id, 'goal');
        release.complete();
        expect(await review, isTrue);
        await analysis;
        expect(engine.calls, 1);
        expect(fixture.state.project.candidates.single.id, 'new');
        expect(fixture.state.canUndoReview, isFalse);
        expect(fixture.state.reviewNotice, isNull);
      } finally {
        await fixture.close();
      }
    },
  );

  test(
    'failed analysis clear preserves reviewed candidates and history',
    () async {
      final fixture = MobileVideoFixture();
      final engine = RecordingAnalysis();
      await fixture.init(engine: engine);
      try {
        final source = await fixture.file('original.mp4', 'original');
        fixture.state.project = fixture.project(source.path);
        expect(
          await fixture.state.updateCandidateNote('goal', 'keep me'),
          isTrue,
        );
        final notice = fixture.state.reviewNotice;
        var first = true;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async {
                if (first) {
                  first = false;
                  throw PlatformException(code: 'analysis_save_failed');
                }
                return fixture.root.path;
              },
            );
        await fixture.state.startAnalysis();
        expect(engine.calls, 0);
        expect(fixture.state.project.candidates.single.note, 'keep me');
        expect(fixture.state.canUndoReview, isTrue);
        expect(fixture.state.reviewNotice, notice);
        expect(fixture.state.diagnosticError, isNotNull);
      } finally {
        await fixture.close();
      }
    },
  );
}
