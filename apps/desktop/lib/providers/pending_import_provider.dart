import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A video path dropped on the home screen, waiting for the import screen to
/// pick it up after the new project opens.
class PendingImportNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String path) => state = path;

  String? take() {
    final path = state;
    state = null;
    return path;
  }
}

final pendingImportProvider = NotifierProvider<PendingImportNotifier, String?>(
  PendingImportNotifier.new,
);

const importVideoExtensions = <String>{'mp4', 'mov', 'm4v', 'avi', 'mkv'};

bool isImportableVideo(String path) {
  final dot = path.lastIndexOf('.');
  return dot >= 0 &&
      importVideoExtensions.contains(path.substring(dot + 1).toLowerCase());
}
