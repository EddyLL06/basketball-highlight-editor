import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:path/path.dart' as p;

import '../video_source/project_paths.dart';
import '../diagnostics/mobile_diagnostics.dart';

class ProjectCatalogItem {
  const ProjectCatalogItem(this.project, this.modifiedAt, this.coverPath);

  final ProjectSnapshot project;
  final DateTime modifiedAt;
  final String? coverPath;
}

class ProjectCatalog {
  const ProjectCatalog(this.items, this.errors);

  final List<ProjectCatalogItem> items;
  final List<Object> errors;
}

/// Lists saved projects, including those evicted from the recent-project index.
Future<ProjectCatalog> readProjectCatalog(Directory data) async {
  final directory = Directory(p.join(data.path, 'projects'));
  if (await FileSystemEntity.type(directory.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    return const ProjectCatalog([], []);
  }
  final items = <ProjectCatalogItem>[];
  final errors = <Object>[];
  await for (final entry in directory.list(followLinks: false)) {
    final name = p.basename(entry.path);
    if (entry is! File || !name.endsWith('.json')) continue;
    final id = name.substring(0, name.length - 5);
    if (!isSafeProjectId(id)) continue;
    try {
      final path = await projectStoragePath(
        data,
        id,
        area: 'projects',
        suffix: '.json',
      );
      final project = const ProjectPackageCodec().decode(
        await File(path).readAsString(),
        includeLocalHistory: true,
      );
      if (project.id != id) {
        throw const FormatException('Project ID does not match file');
      }
      final cover = File(
        await projectStoragePath(
          data,
          id,
          area: 'projects',
          suffix: '_cover.jpg',
        ),
      );
      items.add(
        ProjectCatalogItem(
          project,
          (await entry.stat()).modified,
          await cover.exists() ? cover.path : null,
        ),
      );
    } on Object catch (error, stack) {
      MobileDiagnostics.instance.error(
        error,
        stack,
        operation: 'project.catalog',
      );
      errors.add(error);
    }
  }
  items.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
  return ProjectCatalog(items, errors);
}
