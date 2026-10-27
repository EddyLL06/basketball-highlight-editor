import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:path/path.dart' as p;

/// The recent-project index is capped; older files still reserve their IDs.
Future<Set<String>> existingProjectStorageIds(Directory data) async {
  final ids = <String>{};
  for (final area in ['projects', 'videos', 'exports', 'package_staging']) {
    final directory = Directory(p.join(data.path, area));
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      continue;
    }
    await for (final entry in directory.list(followLinks: false)) {
      final name = p.basename(entry.path);
      final id = area == 'projects'
          ? (entry is File && name.endsWith('.json')
                ? name.substring(0, name.length - 5)
                : '')
          : (entry is Directory ? name : '');
      if (isSafeProjectId(id)) ids.add(id);
    }
  }
  return ids;
}

/// Check both lexical and real paths, including existing symlink ancestors.
Future<String> projectStoragePath(
  Directory data,
  String id, {
  String area = '',
  String suffix = '',
}) async {
  if (!isSafeProjectId(id) ||
      !const [
        '',
        'projects',
        'videos',
        'exports',
        'package_staging',
      ].contains(area) ||
      !const ['', '.json', '_cover.jpg', '.bhe'].contains(suffix)) {
    throw const FormatException('Invalid project storage path');
  }
  final root = await data.resolveSymbolicLinks();
  final parent = p.normalize(p.join(root, area));
  final candidate = p.normalize(p.join(parent, '$id$suffix'));
  var ancestor = candidate;
  final tail = <String>[];
  while (await FileSystemEntity.type(ancestor, followLinks: false) ==
      FileSystemEntityType.notFound) {
    tail.insert(0, p.basename(ancestor));
    ancestor = p.dirname(ancestor);
  }
  final resolved = p.normalize(
    p.joinAll([await File(ancestor).resolveSymbolicLinks(), ...tail]),
  );
  if (!p.isWithin(parent, candidate) || !p.isWithin(parent, resolved)) {
    throw const FormatException('Project path escapes its storage directory');
  }
  return candidate;
}
