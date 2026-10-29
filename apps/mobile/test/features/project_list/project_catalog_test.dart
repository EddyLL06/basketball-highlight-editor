import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bhe_mobile/features/project_list/project_catalog.dart';

void main() {
  test('lists more than 12 saved projects and skips invalid records', () async {
    final root = await Directory.systemTemp.createTemp('bhe-catalog-');
    try {
      final projects = Directory('${root.path}/projects');
      await projects.create();
      for (var i = 0; i < 14; i++) {
        final project = ProjectSnapshot(
          id: 'p$i',
          name: 'Project $i',
          video: null,
        );
        await File(
          '${projects.path}/p$i.json',
        ).writeAsString(const ProjectPackageCodec().encode(project));
      }
      await File('${projects.path}/broken.json').writeAsString('{');
      await File('${projects.path}/wrong.json').writeAsString(
        const ProjectPackageCodec().encode(
          const ProjectSnapshot(id: 'other', name: 'Other', video: null),
        ),
      );
      final catalog = await readProjectCatalog(root);
      expect(catalog.items.length, 14);
      expect(catalog.errors.length, 2);
      expect(catalog.items.map((item) => item.project.id).toSet().length, 14);
    } finally {
      await root.delete(recursive: true);
    }
  });
}
