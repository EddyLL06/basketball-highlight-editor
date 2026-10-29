import 'package:flutter/foundation.dart';
import 'friendly_error.dart';
import 'mobile_diagnostics.dart';

mixin MobileDiagnosticState on ChangeNotifier {
  String? get errorMessage;
  set errorMessage(String? value);
  DiagnosticErrorRecord? diagnosticError;

  void recordDiagnosticFailure(
    Object error,
    StackTrace? stack, {
    String operation = 'project',
  }) {
    final original = error is MobileDiagnosticException ? error.cause : error;
    final context = error is MobileDiagnosticException
        ? error.operation
        : operation;
    final friendly = friendlyMobileError(error, operation: context);
    if (friendly.cancelled) {
      diagnosticError = null;
      errorMessage = null;
      MobileDiagnostics.instance.event('operation.cancelled');
      return;
    }
    diagnosticError = MobileDiagnostics.instance.error(
      original,
      stack,
      operation: context,
    );
    errorMessage = friendly.message;
  }
}
