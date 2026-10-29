/// Desktop keeps its account-only redaction by default. Mobile opts in to
/// directory hiding; recognizable filenames remain for user-submitted reports.
String redactUserPaths(
  String text,
  Map<String, String> env, {
  bool hideDirectories = false,
}) {
  if (hideDirectories) return _hideDiagnosticDirectories(text);
  var out = text;
  final home = env['HOME'] ?? env['USERPROFILE'];
  if (home != null && home.length > 1) out = out.replaceAll(home, '~');
  final user = env['USER'] ?? env['USERNAME'];
  if (user != null && user.length >= 2) {
    out = out.replaceAllMapped(
      RegExp('([\\\\/])${RegExp.escape(user)}(?=[\\\\/])'),
      (m) => '${m[1]}<user>',
    );
  }
  return out.replaceAllMapped(
    RegExp(
      r'''([A-Za-z]:[\\/]+[Uu][Ss][Ee][Rr][Ss][\\/]+|/(?:Users|home)/)([^\\/"'\r\n]+)''',
    ),
    (match) {
      final prefix = match[1]!;
      final name = match[2]!;
      if (RegExp(r'^[A-Za-z]:').hasMatch(prefix) &&
          name.toLowerCase() == 'public') {
        return match[0]!;
      }
      return '${prefix}<user>';
    },
  );
}

// Match quoted paths first, so names with spaces stay together. Unquoted file
// paths end at a filename extension; ambiguous directory-only tails fail closed.
final _diagnosticPath = RegExp(
  r'''(["'])((?:(?:content|file)://|[A-Za-z]:[\\/]+|\\\\+|~/|/)[^\r\n]*?)\1'''
  r'''|(?<![A-Za-z0-9_./\\:>])(?:(?:content|file)://|[A-Za-z]:[\\/]+|\\\\+|~/|/)(?=\S)'''
  r'''(?:(?:(?![ \t]+(?:(?:content|file)://|[A-Za-z]:[\\/]+|\\\\+|~/|/))[^\r\n"'<>?#])*\.[A-Za-z0-9]{1,12}(?::\d+){0,2}(?=$|[\s,;"')\]{}?#])'''
  r'''|(?:(?![ \t]+(?:(?:content|file)://|[A-Za-z]:[\\/]+|\\\\+|~/|/))[^\r\n"'<>?#])+)(?:[?#][^\s"'<>()[\]{}]*)?''',
  caseSensitive: false,
);

String _hideDiagnosticDirectories(String text) =>
    text.replaceAllMapped(_diagnosticPath, (match) {
      final quote = match[1] ?? '';
      final value = match[2] ?? match[0]!;
      return '$quote${_hideDiagnosticPath(value)}$quote';
    });

String _hideDiagnosticPath(String value) {
  final scheme = RegExp(
    r'^(content|file)://',
    caseSensitive: false,
  ).firstMatch(value)?.group(1)?.toLowerCase();
  var path = value;
  var placeholder = '<path>';
  if (scheme != null) {
    placeholder = scheme == 'content' ? 'content://<path>' : '<path>';
    try {
      final uri = Uri.parse(value);
      // pathSegments decodes once and omits authority, query and fragment.
      path = '/${uri.pathSegments.join('/')}';
      // Android document IDs may themselves contain an encoded absolute path.
      for (var i = 0; i < 3 && RegExp(r'%[0-9a-fA-F]{2}').hasMatch(path); i++) {
        path = Uri.decodeComponent(path);
      }
      if (RegExp(r'%[0-9a-fA-F]{2}').hasMatch(path) ||
          path.contains(RegExp(r'[\r\n]'))) {
        return placeholder;
      }
    } on FormatException {
      return placeholder;
    }
  } else {
    path = path.split(RegExp(r'[?#]')).first;
  }
  // A document ID such as "primary:Family/clip.mp4" has a useful basename;
  // opaque media IDs and malformed/ambiguous paths deliberately keep none.
  final normalized = path.replaceAll(RegExp(r'[\\/]+'), '/');
  var prefix = '';
  if (scheme != 'content') {
    final privateRoot = RegExp(
      r'^/data/(?:user(?:_de)?/\d+|data)/[A-Za-z0-9_.]+(?:/|$)',
    ).firstMatch(normalized);
    if (privateRoot != null) {
      prefix = privateRoot[0]!;
      final relative = normalized.substring(prefix.length);
      if (relative.isEmpty ||
          RegExp(r'^files/logs/app\.log(?:\.1)?$').hasMatch(relative)) {
        return normalized;
      }
    }
  }
  final last = normalized.split('/').last;
  final filename = last.replaceFirst(RegExp(r'(?::\d+){1,2}$'), '');
  if (filename.isEmpty ||
      !RegExp(r'^[^/:\x00-\x1f]+\.[A-Za-z0-9]{1,12}$').hasMatch(filename)) {
    return '$prefix$placeholder';
  }
  return '$prefix$placeholder/$last';
}
