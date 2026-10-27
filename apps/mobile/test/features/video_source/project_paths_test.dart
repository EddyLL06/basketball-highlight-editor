import 'dart:convert';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/features/video_source/project_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory data;
  setUp(() async => data = await Directory.systemTemp.createTemp('bhe_paths_'));
  tearDown(() async => data.delete(recursive: true));

  test(
    'unsafe and duplicate package IDs get safe local identities, including v1',
    () {
      const codec = ProjectPackageCodec();
      final encoded =
          jsonDecode(
                codec.encode(
                  const ProjectSnapshot(id: 'A', name: 'A', video: null),
                ),
              )
              as Map<String, dynamic>;
      for (final id in [
        '../projects',
        '/tmp/x',
        r'C:\x',
        '',
        'a' * 65,
        'with space',
        'A\n',
      ]) {
        final restored = codec.decode(
          jsonEncode({...encoded, 'project_id': id}),
        );
        expect(isSafeProjectId(restored.id), isTrue);
        expect(restored.id, isNot(id));
      }
      expect(
        codec.decode(jsonEncode(encoded), existingIds: ['A']).id,
        isNot('A'),
      );
      expect(codec.decode(jsonEncode(encoded)).id, 'A');
      final legacy = codec.decode(
        jsonEncode({
          'format': 'bhe-project',
          'version': 1,
          'project': {'id': '../bad', 'name': 'old'},
        }),
      );
      expect(isSafeProjectId(legacy.id), isTrue);
    },
  );

  test('all project areas reject traversal before any file mutation', () async {
    final sentinel = File('${data.path}/keep.json')..writeAsStringSync('keep');
    for (final area in [
      '',
      'projects',
      'videos',
      'exports',
      'package_staging',
    ]) {
      await expectLater(
        projectStoragePath(data, '../projects', area: area),
        throwsFormatException,
      );
      final result = await projectStoragePath(data, 'safe-A_1', area: area);
      expect(result, contains('safe-A_1'));
    }
    expect(await sentinel.readAsString(), 'keep');
  });

  test('existing symlink ancestors cannot redirect a project path', () async {
    final outside = await Directory.systemTemp.createTemp('bhe_outside_');
    try {
      await Link('${data.path}/videos').create(outside.path);
      await expectLater(
        projectStoragePath(data, 'safe', area: 'videos'),
        throwsFormatException,
      );
      expect(await outside.list().toList(), isEmpty);
    } finally {
      await outside.delete();
    }
  });

  test(
    'projects absent from the recent index still reserve local identities',
    () async {
      final projects = await Directory('${data.path}/projects').create();
      await File('${projects.path}/older.json').writeAsString('old project');
      await Directory('${data.path}/videos/orphaned').create(recursive: true);
      final used = await existingProjectStorageIds(data);
      expect(used, containsAll(['older', 'orphaned']));
      expect(importedProjectId('older', existingIds: used), isNot('older'));
      expect(
        await File('${projects.path}/older.json').readAsString(),
        'old project',
      );
    },
  );
}
