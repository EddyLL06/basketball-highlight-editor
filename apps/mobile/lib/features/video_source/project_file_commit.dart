import 'dart:io';

/// Replace the project and index together; retain originals until both writes
/// finish so a failed index write cannot leave a new video record behind.
class ProjectCommitSuperseded implements Exception {
  const ProjectCommitSuperseded();
}

Future<void> commitProjectFiles(
  Map<File, String> contents, {
  bool Function()? beforeInstall,
  bool Function()? afterInstall,
}) async {
  final token = DateTime.now().microsecondsSinceEpoch;
  final staged = <File, File>{};
  final backups = <File, File>{};
  final installed = <File>[];
  try {
    for (final entry in contents.entries) {
      await entry.key.parent.create(recursive: true);
      final next = File('${entry.key.path}.$token.next');
      staged[entry.key] = next;
      await next.writeAsString(entry.value, flush: true);
    }
    if (beforeInstall != null && !beforeInstall()) {
      throw const ProjectCommitSuperseded();
    }
    for (final file in contents.keys) {
      if (await file.exists()) {
        final backup = File('${file.path}.$token.previous');
        await file.rename(backup.path);
        backups[file] = backup;
      }
      await staged[file]!.rename(file.path);
      installed.add(file);
    }
    if (afterInstall != null && !afterInstall()) {
      throw const ProjectCommitSuperseded();
    }
  } on Object {
    for (final file in installed.reversed) {
      if (await file.exists()) await file.delete();
    }
    for (final entry in backups.entries) {
      await entry.value.rename(entry.key.path);
    }
    rethrow;
  } finally {
    for (final file in staged.values) {
      if (await file.exists()) await file.delete();
    }
  }
  for (final backup in backups.values) {
    try {
      await backup.delete();
    } on FileSystemException {
      /* Recoverable residue. */
    }
  }
}
