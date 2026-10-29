import 'dart:io';

String engineLogDirectory(Map<String, String> env) {
  final home = env['HOME'] ?? env['USERPROFILE'] ?? Directory.systemTemp.path;
  if (Platform.isMacOS) return '$home/Library/Logs/BHE';
  if (Platform.isWindows) return '${env['LOCALAPPDATA'] ?? home}\\BHE\\logs';
  return '${env['XDG_STATE_HOME'] ?? '$home/.local/state'}/bhe/logs';
}

final _latestEnvironment = <String, String>{};

bool isEngineEnvironmentLine(String line) =>
    RegExp(r'^\[[^\]]+\] stderr: \[bhe\] environment ').hasMatch(line);

void appendEngineLog(String message, {File? file}) {
  final target =
      file ??
      File(
        '${engineLogDirectory(Platform.environment)}${Platform.pathSeparator}engine.log',
      );
  try {
    final entry = '[${DateTime.now().toIso8601String()}] $message\n';
    final environment = message.startsWith('stderr: [bhe] environment ');
    final path = target.absolute.path;
    target.parent.createSync(recursive: true);
    if (target.existsSync() && target.lengthSync() > 2 * 1024 * 1024) {
      target.renameSync('${target.path}.1');
      final carried = _latestEnvironment[path];
      if (!environment && carried != null) {
        target.writeAsStringSync(carried, mode: FileMode.append);
      }
    }
    target.writeAsStringSync(entry, mode: FileMode.append);
    if (environment) _latestEnvironment[path] = entry;
  } on Object {
    // Logging must not interrupt the operation that produced the message.
  }
}
