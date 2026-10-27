import 'dart:io';

String engineLogDirectory(Map<String, String> env) {
  final home = env['HOME'] ?? env['USERPROFILE'] ?? Directory.systemTemp.path;
  if (Platform.isMacOS) return '$home/Library/Logs/BHE';
  if (Platform.isWindows) return '${env['LOCALAPPDATA'] ?? home}\\BHE\\logs';
  return '${env['XDG_STATE_HOME'] ?? '$home/.local/state'}/bhe/logs';
}

void appendEngineLog(String message, {File? file}) {
  final target =
      file ??
      File(
        '${engineLogDirectory(Platform.environment)}${Platform.pathSeparator}engine.log',
      );
  try {
    target.parent.createSync(recursive: true);
    if (target.existsSync() && target.lengthSync() > 2 * 1024 * 1024) {
      target.renameSync('${target.path}.1');
    }
    target.writeAsStringSync(
      '[${DateTime.now().toIso8601String()}] $message\n',
      mode: FileMode.append,
    );
  } on Object {
    // Logging must not interrupt the operation that produced the message.
  }
}
