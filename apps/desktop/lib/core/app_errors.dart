import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'app_log.dart';

class AppErrorRecorder {
  AppErrorRecorder({void Function(String)? write})
    : _write = write ?? appendEngineLog;

  final void Function(String) _write;
  final _pending = <String, _ErrorWindow>{};
  int _sequence = 0;

  void record(String source, Object error, StackTrace stack) {
    try {
      final message = error.toString();
      final existing = _pending[message];
      if (existing != null) {
        if (existing.age.elapsed < const Duration(seconds: 1)) {
          existing.count++;
          return;
        }
        _finish(message);
      }
      final entry = _ErrorWindow(++_sequence);
      _pending[message] = entry;
      entry.timer = Timer(const Duration(seconds: 1), () => _finish(message));
      final frames = stack.toString().split('\n');
      _write(
        'app error: source=$source id=${entry.id} count=1 error=${jsonEncode(message)} stack_truncated=${frames.length > 30}',
      );
      for (final frame in frames.take(30)) {
        _write('app error: id=${entry.id} stack $frame');
      }
    } on Object {
      // Error reporting must not become another uncaught error.
    }
  }

  void _finish(String message) {
    final entry = _pending.remove(message);
    if (entry == null) return;
    entry.timer?.cancel();
    if (entry.count > 1) {
      try {
        _write(
          'app error: id=${entry.id} repeated=${entry.count - 1} total=${entry.count} window_ms=1000',
        );
      } on Object {
        // Keep the original error chain independent from the log sink.
      }
    }
  }

  void dispose() {
    for (final message in _pending.keys.toList()) {
      _finish(message);
    }
  }
}

class _ErrorWindow {
  _ErrorWindow(this.id);
  final int id;
  final age = Stopwatch()..start();
  int count = 1;
  Timer? timer;
}

VoidCallback installAppErrorHandlers(AppErrorRecorder recorder) {
  final oldFlutter = FlutterError.onError;
  final dispatcher = PlatformDispatcher.instance;
  final oldPlatform = dispatcher.onError;
  FlutterError.onError = (details) {
    recorder.record(
      'flutter',
      details.exception,
      details.stack ?? StackTrace.current,
    );
    (oldFlutter ?? FlutterError.presentError)(details);
  };
  dispatcher.onError = (error, stack) {
    recorder.record('platform', error, stack);
    return oldPlatform?.call(error, stack) ?? false;
  };
  return () {
    FlutterError.onError = oldFlutter;
    dispatcher.onError = oldPlatform;
  };
}

void runWithAppErrorLogging(
  Future<void> Function() start, {
  AppErrorRecorder? recorder,
}) {
  final sink = recorder ?? AppErrorRecorder();
  final parent = Zone.current;
  runZonedGuarded(
    () async {
      installAppErrorHandlers(sink);
      await start();
    },
    (error, stack) {
      sink.record('zone', error, stack);
      parent.handleUncaughtError(error, stack);
    },
  );
}
