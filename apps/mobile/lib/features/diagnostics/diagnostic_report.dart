import 'diagnostic_redaction.dart';
import 'mobile_diagnostics.dart';

Future<String> buildMobileDiagnosticReport(
  MobileDiagnostics diagnostics, {
  DiagnosticErrorRecord? error,
  required String Function(String) text,
}) async {
  final snapshot = await diagnostics.snapshot();
  final buffer = StringBuffer()..writeln(text('BHE 诊断信息'));
  const labels = {
    'app_version': 'App 版本',
    'android': '安卓版本',
    'sdk': 'SDK',
    'manufacturer': '厂商',
    'model': '手机型号',
    'abi': 'CPU 架构',
    'memory_total': '总内存',
    'memory_available': '可用内存',
    'storage_available': '可用存储',
    'screen': '屏幕尺寸',
    'language': '语言',
  };
  for (final entry in labels.entries) {
    final value = snapshot.environment[entry.key];
    buffer.writeln('${text(entry.value)}: ${value ?? text('未知')}');
  }
  if (error != null) {
    buffer
      ..writeln()
      ..writeln(text('当前错误'))
      ..writeln(
        redactDiagnosticText(
          '${error.error}\n${error.stack?.toString().split('\n').take(30).join('\n') ?? ''}',
        ),
      );
  }
  buffer
    ..writeln()
    ..writeln(text('最近的运行日志'));
  if (snapshot.lines.isEmpty) {
    buffer.writeln(text(snapshot.available ? '没有找到运行日志' : '运行日志暂不可用'));
  } else {
    // Never synthesize a startup line. Only report the actual native log tail.
    buffer.writeln(snapshot.lines.map(redactDiagnosticText).join('\n'));
  }
  return buffer.toString();
}
