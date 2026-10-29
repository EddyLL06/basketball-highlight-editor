import 'dart:async';
import 'dart:io';

import 'package:desktop/core/app_errors.dart';
import 'package:desktop/core/app_log.dart';
import 'package:desktop/core/engine_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('records one stack, at most 30 frames, and a repeat count', () async {
    final lines = <String>[];
    final sink = AppErrorRecorder(write: lines.add);
    final stack = StackTrace.fromString(
      List.generate(40, (i) => '#$i frame').join('\n'),
    );
    for (var i = 0; i < 5; i++) {
      sink.record('flutter', StateError('preview failed'), stack);
    }
    await Future<void>.delayed(const Duration(milliseconds: 1050));
    expect(
      lines.where((line) => line.contains('preview failed')),
      hasLength(1),
    );
    expect(lines.where((line) => line.contains(' stack ')), hasLength(30));
    expect(lines.first, contains('stack_truncated=true'));
    expect(lines.last, contains('repeated=4 total=5'));
    sink.record('flutter', StateError('preview failed'), stack);
    expect(
      lines.where((line) => line.contains('preview failed')),
      hasLength(2),
    );
    sink.dispose();
  });

  test('framework and platform handlers forward every original call', () {
    final lines = <String>[];
    var flutterCalls = 0;
    var platformCalls = 0;
    final oldFlutter = FlutterError.onError;
    final oldPlatform = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = oldFlutter;
      PlatformDispatcher.instance.onError = oldPlatform;
    });
    FlutterError.onError = (_) => flutterCalls++;
    PlatformDispatcher.instance.onError = (_, _) {
      platformCalls++;
      return false;
    };
    final sink = AppErrorRecorder(write: lines.add);
    final restore = installAppErrorHandlers(sink);
    final error = StateError('shared error');
    for (var i = 0; i < 2; i++) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: StackTrace.current),
      );
      expect(
        PlatformDispatcher.instance.onError!(error, StackTrace.current),
        isFalse,
      );
    }
    expect(flutterCalls, 2);
    expect(platformCalls, 2);
    sink.dispose();
    restore();
    expect(lines.where((line) => line.contains('shared error')), hasLength(1));
  });

  test('zone errors are logged and forwarded to the parent zone', () async {
    final lines = <String>[];
    final sink = AppErrorRecorder(write: lines.add);
    final forwarded = Completer<Object>();
    final oldFlutter = FlutterError.onError;
    final oldPlatform = PlatformDispatcher.instance.onError;
    runZonedGuarded(
      () {
        runWithAppErrorLogging(() async {
          throw StateError('zone failure');
        }, recorder: sink);
      },
      (error, _) {
        forwarded.complete(error);
      },
    );
    expect(await forwarded.future, isA<StateError>());
    expect(lines.first, contains('source=zone'));
    FlutterError.onError = oldFlutter;
    PlatformDispatcher.instance.onError = oldPlatform;
    sink.dispose();
  });

  test('global and engine messages use the same rotating file', () async {
    final dir = await Directory.systemTemp.createTemp('bhe-app-log');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/engine.log');
    file.writeAsStringSync('x' * (2 * 1024 * 1024 + 1));
    final client = EngineClient(logFile: file);
    client.log('engine entry');
    final sink = AppErrorRecorder(
      write: (line) => appendEngineLog(line, file: file),
    );
    sink.record(
      'flutter',
      StateError('app entry'),
      StackTrace.fromString('#0 test'),
    );
    sink.dispose();
    expect(File('${file.path}.1').existsSync(), isTrue);
    expect(file.readAsStringSync(), contains('engine entry'));
    expect(file.readAsStringSync(), contains('app error:'));
    final bad = File('${file.path}/child');
    expect(() => appendEngineLog('cannot write', file: bad), returnsNormally);
    final broken = AppErrorRecorder(
      write: (_) => throw FileSystemException('bad sink'),
    );
    expect(
      () =>
          broken.record('flutter', StateError('original'), StackTrace.current),
      returnsNormally,
    );
    broken.dispose();
  });
}
