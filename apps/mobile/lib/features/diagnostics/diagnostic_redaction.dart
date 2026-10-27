/// Fail closed until the reviewed shared redactor can be migrated after diag merges.
/// All raw diagnostic text enters through this one boundary, including stack traces.
String redactDiagnosticText(String text) =>
    text.isEmpty ? '' : '[diagnostic details temporarily withheld]';
