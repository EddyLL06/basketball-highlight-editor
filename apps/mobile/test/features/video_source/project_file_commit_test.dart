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
}
