import 'package:bhe_core/bhe_core.dart';
import 'package:test/test.dart';

void main() {
  for (final entry in <String, String>{
    '/storage/emulated/0/Family/project/game.mp4': '<path>/game.mp4',
    'failed /storage/My Team/game.mp4 errno=28':
        'failed <path>/game.mp4 errno=28',
    '/sdcard/Private.mp4 Secret Team/game.mp4': '<path>/game.mp4',
    '/sdcard/Team (Parent)/game.mp4': '<path>/game.mp4',
    '/sdcard/Team (Parent)/Private Data': '<path>',
    'content://private.authority/Private (Team)/game.mp4?token=secret':
        'content://<path>/game.mp4',
    '/sdcard/私人目录/比赛 视频.mp4': '<path>/比赛 视频.mp4',
    '"/storage/emulated/0/My Team/game one.mp4"': '"<path>/game one.mp4"',
    "path = '/storage/emulated/0/My Team/game one.mp4' (errno=28)":
        "path = '<path>/game one.mp4' (errno=28)",
    '/mnt/media_rw/ABCD-EF01/Team/game.mp4': '<path>/game.mp4',
    '/Users/former account/Movies/game.mp4': '<path>/game.mp4',
    '/home/former account/videos/game.mp4': '<path>/game.mp4',
    '~/Personal/game.mp4': '<path>/game.mp4',
    r'C:\Users\old name\Desktop\game.mp4': '<path>/game.mp4',
    r'"C:\\Users\\old name\\Desktop\\game.mp4"': '"<path>/game.mp4"',
    r'\\private-server\shared-team\game.mp4': '<path>/game.mp4',
    'file:///storage/emulated/0/Private%20Team/game%20one.mp4?token=secret#secret':
        '<path>/game one.mp4',
    'file:///storage/emulated/0/My Team/game.mp4': '<path>/game.mp4',
    'file://private-computer/Team/game.mp4': '<path>/game.mp4',
    '(file:///Us' 'ers/old%20name/src/main.dart:12:5)': '(<path>/main.dart:12:5)',
    'content://private.authority/document/primary%3AFamily%2Fgame%20one.mp4?secret=1#secret':
        'content://<path>/game one.mp4',
    'content://private.authority/document/primary%253AFamily%252Fgame.mp4':
        'content://<path>/game.mp4',
    'content://private.authority/external/video/media/123?secret=1':
        'content://<path>',
    'content://private.authority/folder/no-file': 'content://<path>',
    '/data/user/0/com.bhe.bhe_mobile/': '/data/user/0/com.bhe.bhe_mobile/',
    '/data/user/0/com.bhe.bhe_mobile/files/logs/app.log':
        '/data/user/0/com.bhe.bhe_mobile/files/logs/app.log',
    '/data/user/0/com.bhe.bhe_mobile/files/logs/app.log.1':
        '/data/user/0/com.bhe.bhe_mobile/files/logs/app.log.1',
    '/data/user/0/com.bhe.bhe_mobile/files/My Team/game.mp4':
        '/data/user/0/com.bhe.bhe_mobile/<path>/game.mp4',
    '/data/data/com.bhe.bhe_mobile/cache/My Team/game.mp4':
        '/data/data/com.bhe.bhe_mobile/<path>/game.mp4',
    '/data/user_de/0/com.bhe.bhe_mobile/files/My Team/game.mp4':
        '/data/user_de/0/com.bhe.bhe_mobile/<path>/game.mp4',
    '/storage/emulated/0/Private Team/': '<path>',
    '/storage/emulated/0/Private Team': '<path>',
    'muxer rejected video/hevc and audio/apac':
        'muxer rejected video/hevc and audio/apac',
    'package:bhe_mobile/features/main.dart:12:5':
        'package:bhe_mobile/features/main.dart:12:5',
    'failed /sdcard/private/first.mp4 and /sdcard/other/second.mp4':
        'failed <path>/first.mp4 and <path>/second.mp4',
    '"file:///private/Team/goal.mp4?token=secret"': '"<path>/goal.mp4"',
    'content://private.authority/document/%FF%FF.mp4?token=secret':
        'content://<path>',
    'file:///private/Team/%FF%FF.mp4?token=secret': '<path>',
    'content://private.authority/document/primary%25252525252Fsecret':
        'content://<path>',
  }.entries) {
    test('mobile directory redaction: ${entry.key}', () {
      final actual = redactUserPaths(
        entry.key,
        const {},
        hideDirectories: true,
      );
      expect(actual, entry.value);
      expect(
        redactUserPaths(actual, const {}, hideDirectories: true),
        actual,
        reason:
            'The same text is sanitized before logging and again before copying.',
      );
    });
  }
  test('mobile mode is independent from the developer machine environment', () {
    expect(
      redactUserPaths('/Us' 'ers/alice/My Team/game.mp4', const {
        'HOME': '/Users/alice',
        'USER': 'alice',
      }, hideDirectories: true),
      '<path>/game.mp4',
    );
    expect(redactUserPaths('', const {}, hideDirectories: true), '');
  });
}
