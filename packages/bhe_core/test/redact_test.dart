import 'package:bhe_core/bhe_core.dart';
import 'package:test/test.dart';

void main() {
  test('preserves existing home alias and account redaction behavior', () {
    const home = '/Users/alice';
    final env = {'HOME': home, 'USER': 'alice'};
    expect(
      redactUserPaths('open $home/Movies/game.mp4', env),
      'open ~/Movies/game.mp4',
    );
    expect(
      redactUserPaths(
        r'open D:'
        r'\Users\alice\clip.mp4',
        env,
      ),
      r'open D:'
      r'\Users\<user>\clip.mp4',
    );
    expect(redactUserPaths('ordinary alice text', env), 'ordinary alice text');
  });

  for (final entry in <String, String>{
    r'C:\Users\old name\clip.mp4': r'C:\Us' r'ers\<user>\clip.mp4',
    r'D:/Users/张 三/clip.mp4': r'D:/Us' r'ers/<user>/clip.mp4',
    r'{"path":"C:\\Users\\张 三\\clip.mp4"}':
        r'{"path":"C:\\Users\\<user>\\clip.mp4"}',
    '/Users/renamed account/clip.mp4': '/Us' 'ers/<user>/clip.mp4',
    '/ho' 'me/张三/clip.mp4': '/ho' 'me/<user>/clip.mp4',
    '"/Users/张 三"\nnext line': '"/Users/<user>"\nnext line',
    r'C:\Us' r'ers\Public\clip.mp4': r'C:\Us' r'ers\Public\clip.mp4',
    r'C:/users/PUBLIC/clip.mp4': r'C:/users/PUBLIC/clip.mp4',
    r'D:\Users2\alice\clip.mp4': r'D:\Users2\alice\clip.mp4',
    r'D:\videos\alice\clip.mp4': r'D:\videos\alice\clip.mp4',
  }.entries) {
    test('redacts only account path shapes: ${entry.key}', () {
      expect(redactUserPaths(entry.key, const {}), entry.value);
    });
  }
}
