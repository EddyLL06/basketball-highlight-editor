import 'dart:math';

bool isSafeProjectId(String id) =>
    RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id);

/// Package IDs are untrusted input, never filesystem paths.
String importedProjectId(
  Object? value, {
  Iterable<String> existingIds = const [],
}) {
  final used = existingIds.toSet();
  if (value is String && isSafeProjectId(value) && !used.contains(value)) {
    return value;
  }
  final random = Random.secure();
  String id;
  do {
    id =
        '${DateTime.now().microsecondsSinceEpoch}_'
        '${List.generate(12, (_) => random.nextInt(16).toRadixString(16)).join()}';
  } while (used.contains(id));
  return id;
}
