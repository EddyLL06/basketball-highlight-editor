import 'package:bhe_core/bhe_core.dart' show redactUserPaths;

/// The same shared redactor protects writes, previews and clipboard reports.
String redactDiagnosticText(String text) =>
    redactUserPaths(text, const {}, hideDirectories: true);
