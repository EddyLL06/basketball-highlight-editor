import 'dart:io';

import 'package:desktop/core/app_log.dart';
import 'package:desktop/core/diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'environment is carried with original timestamp through many rotations',
    () async {
      final dir = await Directory.systemTemp.createTemp('bhe-env-rotation');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/engine.log');
      appendEngineLog('stderr: [bhe] environment engine=test', file: file);
      final original = file.readAsLinesSync().first;
      for (var i = 0; i < 3; i++) {
        appendEngineLog('x' * (2 * 1024 * 1024), file: file);
        appendEngineLog('iteration $i', file: file);
        expect(file.readAsLinesSync().first, original);
      }
      for (var i = 0; i < 350; i++) {
        appendEngineLog('recent $i', file: file);
      }
      final tail = (await readLogTail(dir.path, 300)).split('\n');
      expect(tail, hasLength(300));
      expect(tail.first, original);
      expect(tail.last, contains('recent 349'));
      expect(tail.where(isEngineEnvironmentLine), hasLength(1));
      expect(
        dir
            .listSync()
            .map((file) => file.path.split(Platform.pathSeparator).last)
            .toSet(),
        {'engine.log', 'engine.log.1'},
      );
    },
  );

  test(
    'a new environment replaces the memory entry and failures do not recurse',
    () async {
      final dir = await Directory.systemTemp.createTemp('bhe-env-new');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/engine.log');
      appendEngineLog('stderr: [bhe] environment engine=old', file: file);
      appendEngineLog('stderr: [bhe] environment engine=new', file: file);
      final latest = file.readAsLinesSync().last;
      appendEngineLog('x' * (2 * 1024 * 1024), file: file);
      appendEngineLog('next', file: file);
      expect(file.readAsLinesSync().first, latest);
      expect(
        () => appendEngineLog(
          'stderr: [bhe] environment broken',
          file: File('${file.path}/child'),
        ),
        returnsNormally,
      );
      expect(file.readAsLinesSync().first, latest);
    },
  );

  test(
    'reports retain a real environment in 300 lines and never invent one',
    () async {
      final home = await Directory.systemTemp.createTemp('bhe-env-report');
      addTearDown(() => home.delete(recursive: true));
      final env = {'HOME': home.path, 'LOCALAPPDATA': home.path};
      final file = File('${engineLogDirectory(env)}/engine.log');
      appendEngineLog('stderr: [bhe] environment engine=real', file: file);
      for (var i = 0; i < 400; i++) {
        appendEngineLog('tail $i', file: file);
      }
      final report = await buildDiagnosticReport(environment: env);
      expect(report, contains('environment engine=real'));
      expect(report, contains('tail 399'));
      file.writeAsStringSync('only data\n');
      expect(await readLogTail(file.parent.path, 300), 'only data');
      expect(await readLogTail(file.parent.path, 0), isEmpty);
    },
  );
}
