String redactUserPaths(String text, Map<String, String> env) {
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
