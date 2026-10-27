import 'dart:ffi' show Abi;
import 'dart:io';

import 'app_log.dart';

/// 打包时由 `--dart-define=BHE_VERSION=<版本>` 注入，本地开发显示 dev。
const appVersion = String.fromEnvironment('BHE_VERSION', defaultValue: 'dev');

/// 用户反馈时复制的诊断信息：版本、系统、错误详情和最近的运行日志。
/// 用户目录和用户名会被替换掉，避免把个人信息发出去。
Future<String> buildDiagnosticReport({
  String? error,
  Map<String, String>? environment,
  int logLines = 300,
}) async {
  final env = environment ?? Platform.environment;
  final buffer = StringBuffer()
    ..writeln('BHE 诊断信息')
    ..writeln('版本: $appVersion')
    ..writeln(
      '系统: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    )
    ..writeln('架构: ${Abi.current()}')
    ..writeln('CPU 核数: ${Platform.numberOfProcessors}')
    ..writeln('语言: ${Platform.localeName}');
  if (error != null && error.trim().isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('错误:')
      ..writeln(error.trim());
  }
  final log = await readLogTail(engineLogDirectory(env), logLines);
  buffer
    ..writeln()
    ..writeln('最近的运行日志:')
    ..writeln(log.isEmpty ? '(没有找到运行日志)' : log);
  return redactUserPaths(buffer.toString(), env);
}

/// 读 engine.log 的最后几行；不够时从轮换出去的 engine.log.1 补。
Future<String> readLogTail(String directory, int lines) async {
  if (lines <= 0) return '';
  final collected = <String>[];
  for (final name in const ['engine.log.1', 'engine.log']) {
    try {
      final file = File('$directory${Platform.pathSeparator}$name');
      if (await file.exists()) collected.addAll(await file.readAsLines());
    } on Object {
      // A missing or unreadable log must not break diagnostic copying.
    }
  }
  final tail = collected.length > lines
      ? collected.sublist(collected.length - lines)
      : List<String>.from(collected);
  final environment = collected.where(isEngineEnvironmentLine).lastOrNull;
  if (environment != null && !tail.contains(environment)) {
    if (tail.length == lines) tail.removeAt(0);
    tail.insert(0, environment);
  }
  return tail.join('\n');
}

String redactUserPaths(String text, Map<String, String> env) {
  var out = text;
  final home = env['HOME'] ?? env['USERPROFILE'];
  if (home != null && home.length > 1) out = out.replaceAll(home, '~');
  final user = env['USER'] ?? env['USERNAME'];
  if (user != null && user.length >= 2) {
    out = out.replaceAllMapped(
      RegExp('([\\\\/])${RegExp.escape(user)}(?=[\\\\/])'),
      (m) => '${m[1]}<user>',
    );
  }
  return out;
}
