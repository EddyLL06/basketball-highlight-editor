import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../app_updater.dart';
import 'mobile_diagnostics.dart';

typedef DiagnosticCapture = void Function(Object error, StackTrace? stack);

/// Chaining is independent from the writer: logging failures never consume errors.
class DiagnosticErrorHooks {
  DiagnosticErrorHooks(this.capture);
  final DiagnosticCapture capture;
  FlutterExceptionHandler? _flutter;
  ErrorCallback? _platform;
  bool _installed = false;
  void _record(Object error, StackTrace? stack) {
    try {
      capture(error, stack);
    } catch (_) {}
  }

  void install() {
    if (_installed) return;
    _installed = true;
    _flutter = FlutterError.onError;
    _platform = PlatformDispatcher.instance.onError;
    FlutterError.onError = (details) {
      _record(details.exception, details.stack);
      if (_flutter != null) {
        _flutter!(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _record(error, stack);
      return _platform?.call(error, stack) ?? false;
    };
  }

  void restore() {
    if (!_installed) return;
    FlutterError.onError = _flutter;
    PlatformDispatcher.instance.onError = _platform;
    _installed = false;
  }
}

/// Binding initialization and runApp must share this zone.
void runDiagnosticZone(
  void Function() start,
  DiagnosticCapture capture, {
  DiagnosticCapture? forward,
}) {
  final parent = Zone.current;
  runZonedGuarded(start, (error, stack) {
    try {
      capture(error, stack);
    } catch (_) {}
    if (forward != null) {
      forward(error, stack);
    } else {
      parent.handleUncaughtError(error, stack);
    }
  });
}

void runWithMobileDiagnostics(Widget app) {
  final diagnostics = MobileDiagnostics(const MethodChannelDiagnosticBackend());
  runDiagnosticZone(() {
    WidgetsFlutterBinding.ensureInitialized();
    MobileDiagnostics.instance = diagnostics;
    DiagnosticErrorHooks(
      (error, stack) => diagnostics.error(error, stack),
    ).install();
    unawaited(
      diagnostics.initialize(
        version: mobileAppVersion,
        language: PlatformDispatcher.instance.locale.toLanguageTag(),
      ),
    );
    runApp(app);
  }, (error, stack) => diagnostics.error(error, stack));
}
