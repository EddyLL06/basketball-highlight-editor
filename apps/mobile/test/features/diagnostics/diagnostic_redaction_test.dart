import 'package:bhe_mobile/features/diagnostics/diagnostic_redaction.dart';
import 'package:bhe_core/bhe_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mobile boundary delegates directory hiding to the shared redactor', () {
    expect(
      redactDiagnosticText('/storage/emulated/0/private/game.mp4'),
      '<path>/game.mp4',
    );
    expect(redactDiagnosticText(''), '');
  });
  test(
    'mobile uses the exact shared contact destinations and bilingual template',
    () {
      expect(githubIssueUrl, contains('/issues/new?template=bug_report.yml'));
      expect(
        feedbackMailto(appVersion: '0.1.13+android.1'),
        startsWith('mailto:$feedbackEmail?'),
      );
      expect(
        Uri.parse(feedbackMailto(english: true)).queryParameters['body'],
        contains('Description:'),
      );
      expect(
        Uri.parse(feedbackMailto()).queryParameters['body'],
        contains('问题描述：'),
      );
    },
  );
}
