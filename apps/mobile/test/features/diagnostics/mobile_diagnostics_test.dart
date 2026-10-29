import 'dart:async';
import 'package:bhe_mobile/features/diagnostics/mobile_diagnostics.dart';
import 'package:bhe_mobile/features/diagnostics/diagnostics_bootstrap.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeDiagnosticBackend implements DiagnosticBackend {
  final messages = <String>[];
  final keys = <String?>[];
  bool fail = false;
  String? version;
  @override
  Future<void> initialize(String value, String language) async {
    version = value;
    if (fail) throw StateError('disk');
  }

  @override
  Future<void> append(String message, String? key) async {
    if (fail) throw StateError('disk');
    messages.add(message);
    keys.add(key);
  }

  @override
  Future<DiagnosticSnapshot> snapshot() async {
    if (fail) throw StateError('disk');
    return const DiagnosticSnapshot(
      environment: {'model': 'Fake device'},
      lines: ['one', 'two'],
      available: true,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'facade preserves version, bounds stacks and keeps raw paths out of the bridge',
    () async {
      final backend = FakeDiagnosticBackend();
      final diagnostics = MobileDiagnostics(backend);
      await diagnostics.initialize(version: '0.1.13+android.1', language: 'en');
      final error = StateError('/storage/emulated/0/private/game.mp4');
      final stack = StackTrace.fromString(
        List.generate(60, (i) => 'frame$i /private/path.dart').join('\n'),
      );
      diagnostics.error(error, stack);
      diagnostics.error(error, stack);
      diagnostics.event('project.open', available: false);
      await pumpEventQueue();
      expect(backend.version, '0.1.13+android.1');
      expect(backend.messages.first, startsWith('app error:'));
      expect(backend.messages.first.split('\n'), hasLength(31));
      expect(backend.messages.first, contains('Bad state: <path>/game.mp4'));
      expect(backend.messages.first, contains('frame0 <path>/path.dart'));
      expect(backend.messages.join(), isNot(contains('/storage')));
      expect(backend.keys[0], backend.keys[1]);
      expect(backend.messages.last, contains('available=false'));
      final snapshot = await diagnostics.snapshot();
      expect(snapshot.environment['app_version'], '0.1.13+android.1');
      expect(snapshot.environment['model'], 'Fake device');
      expect(snapshot.lines, ['one', 'two']);
    },
  );
  test('writer failures never escape and snapshots remain usable', () async {
    final diagnostics = MobileDiagnostics(FakeDiagnosticBackend()..fail = true);
    await diagnostics.initialize(version: 'dev', language: 'zh');
    diagnostics.error(StateError('original'), StackTrace.current);
    diagnostics.event('export.start');
    await pumpEventQueue();
    final snapshot = await diagnostics.snapshot();
    expect(snapshot.available, isFalse);
    expect(snapshot.environment['app_version'], 'dev');
    expect(snapshot.lines, isEmpty);
  });
  test(
    'method channel sends sanitized records and accepts null package info',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(
        MethodChannelDiagnosticBackend.channel,
        (call) async {
          calls.add(call);
          if (call.method == 'snapshot') {
            return {
              'environment': {'native_package_version': null},
              'lines': <String>[],
              'available': true,
            };
          }
          return null;
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          MethodChannelDiagnosticBackend.channel,
          null,
        ),
      );
      final diagnostics = MobileDiagnostics(
        const MethodChannelDiagnosticBackend(),
      );
      await diagnostics.initialize(version: '0.1.13+android.2', language: 'en');
      diagnostics.error(StateError('/private/video.mp4'), null);
      await pumpEventQueue();
      expect(calls.map((c) => c.method), ['initialize', 'append']);
      expect(calls.last.arguments['message'], isNot(contains('/private')));
      expect(
        (await diagnostics.snapshot()).environment['native_package_version'],
        isNull,
      );
    },
  );
  for (final result in [false, true]) {
    test(
      'global hooks call originals once and preserve platform return $result',
      () {
        final oldFlutter = FlutterError.onError;
        final oldPlatform = PlatformDispatcher.instance.onError;
        var frameworkCalls = 0;
        var platformCalls = 0;
        var captured = 0;
        FlutterError.onError = (_) {
          frameworkCalls++;
        };
        PlatformDispatcher.instance.onError = (_, _) {
          platformCalls++;
          return result;
        };
        final hooks = DiagnosticErrorHooks((_, _) {
          captured++;
        });
        try {
          hooks.install();
          FlutterError.reportError(
            FlutterErrorDetails(exception: StateError('framework')),
          );
          expect(
            PlatformDispatcher.instance.onError!(
              StateError('platform'),
              StackTrace.current,
            ),
            result,
          );
          expect(frameworkCalls, 1);
          expect(platformCalls, 1);
          expect(captured, 2);
        } finally {
          hooks.restore();
          FlutterError.onError = oldFlutter;
          PlatformDispatcher.instance.onError = oldPlatform;
        }
      },
    );
  }
  test('a failing diagnostic sink still delegates original handlers', () {
    final previous = FlutterError.onError;
    var called = 0;
    FlutterError.onError = (_) {
      called++;
    };
    final hooks = DiagnosticErrorHooks((_, _) => throw StateError('logger'));
    try {
      hooks.install();
      FlutterError.reportError(
        FlutterErrorDetails(exception: StateError('original')),
      );
      expect(called, 1);
    } finally {
      hooks.restore();
      FlutterError.onError = previous;
    }
  });
  test('guarded-zone capture forwards original exception', () async {
    final done = Completer<void>();
    final failure = StateError('zone');
    var recorded = 0;
    var forwarded = 0;
    runDiagnosticZone(
      () {
        scheduleMicrotask(() => throw failure);
      },
      (error, _) {
        expect(error, same(failure));
        recorded++;
      },
      forward: (error, _) {
        expect(error, same(failure));
        forwarded++;
        done.complete();
      },
    );
    await done.future;
    expect(recorded, 1);
    expect(forwarded, 1);
  });
}
