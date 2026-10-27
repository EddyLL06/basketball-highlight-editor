import 'dart:io';

export 'package:bhe_core/bhe_core.dart'
    show feedbackEmail, feedbackMailto, githubIssueUrl;

Future<bool> openExternalUri(String uri) async {
  final result = switch (Platform.operatingSystem) {
    'macos' => await Process.run('open', <String>[uri]),
    'windows' => await Process.run('cmd', <String>['/c', 'start', '', uri]),
    _ => await Process.run('xdg-open', <String>[uri]),
  };
  return result.exitCode == 0;
}
