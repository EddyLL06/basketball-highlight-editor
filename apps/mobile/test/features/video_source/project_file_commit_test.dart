import 'dart:io';

import 'package:bhe_mobile/features/video_source/project_file_commit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('failed index install restores the original project record', () async {
    final root = await Directory.systemTemp.createTemp('bhe_commit_');
    try {
      final project = File('${root.path}/A.json');
      await project.writeAsString('old record');
      final index = File('${root.path}/index.json');
      await Directory(index.path).create();
      await expectLater(
        commitProjectFiles({project: 'new record', index: 'new index'}),
        throwsA(isA<FileSystemException>()),
      );
      expect(await project.readAsString(), 'old record');
      expect(await Directory(index.path).exists(), isTrue);
      expect((await root.list().toList()).length, 2);
    } finally {
      await root.delete(recursive: true);
    }
  });
  test(
    'superseded staged write never installs or deletes existing files',
    () async {
      final root = await Directory.systemTemp.createTemp('bhe_commit_guard_');
      try {
        final project = File('${root.path}/A.json');
        final index = File('${root.path}/index.json');
        await project.writeAsString('old project');
        await index.writeAsString('old index');
        await expectLater(
          commitProjectFiles({
            project: 'new project',
            index: 'new index',
          }, beforeInstall: () => false),
          throwsA(isA<ProjectCommitSuperseded>()),
        );
        expect(await project.readAsString(), 'old project');
        expect(await index.readAsString(), 'old index');
        expect((await root.list().toList()).length, 2);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'superseded installed write restores both existing files from backups',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'bhe_commit_guard_after_',
      );
      try {
        final project = File('${root.path}/A.json');
        final index = File('${root.path}/index.json');
        await project.writeAsString('old project');
        await index.writeAsString('old index');
        await expectLater(
          commitProjectFiles({
            project: 'new project',
            index: 'new index',
          }, afterInstall: () => false),
          throwsA(isA<ProjectCommitSuperseded>()),
        );
        expect(await project.readAsString(), 'old project');
        expect(await index.readAsString(), 'old index');
        expect((await root.list().toList()).length, 2);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
