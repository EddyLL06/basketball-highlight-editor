import 'dart:io';

import 'package:desktop/core/app_log.dart';
import 'package:desktop/core/diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'update tail contains at most 60 recent entries and is redacted',
    () async {
      final home = await Directory.systemTemp.createTemp('bhe-update-diag');
      addTearDown(() => home.delete(recursive: true));
      final env = {'HOME': home.path, 'LOCALAPPDATA': home.path};
      final dir = Directory(engineLogDirectory(env))
        ..createSync(recursive: true);
      final file = File('${dir.path}/update.log');
      file.writeAsStringSync(
        List.generate(
          80,
          (i) => 'update $i path=/Users/old name/BHE',
        ).join('\n'),
      );
      final report = await buildDiagnosticReport(environment: env);
      expect(report, contains('最近的更新日志:'));
      expect(report, contains('update 20 '));
      expect(report, isNot(contains('update 19 ')));
      expect(report, contains('update 79 '));
      expect(report, contains('/Us' 'ers/<user>/BHE'));
      expect(report.indexOf('最近的运行日志:'), lessThan(report.indexOf('最近的更新日志:')));
      expect((await readUpdateLogTail(dir.path)).split('\n'), hasLength(60));
    },
  );

  test('missing, empty, and unreadable update logs are omitted', () async {
    final home = await Directory.systemTemp.createTemp('bhe-update-empty');
    addTearDown(() => home.delete(recursive: true));
    final env = {'HOME': home.path, 'LOCALAPPDATA': home.path};
    expect(
      await buildDiagnosticReport(environment: env),
      isNot(contains('最近的更新日志:')),
    );
    final dir = Directory(engineLogDirectory(env))..createSync(recursive: true);
    final file = File('${dir.path}/update.log')..writeAsStringSync('');
    expect(
      await buildDiagnosticReport(environment: env),
      isNot(contains('最近的更新日志:')),
    );
    file.deleteSync();
    Directory(file.path).createSync();
    expect(await readUpdateLogTail(dir.path), isEmpty);
  });
}
