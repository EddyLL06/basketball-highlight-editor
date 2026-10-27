import 'package:bhe_core/bhe_core.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> manifest({Object? version, Object? notes}) => {
  'version': '0.1.13',
  'notes': {'zh': '全量', 'en': 'Full'},
  'packages': {
    'android-arm64-v8a': {
      'url': 'https://example.invalid/app.apk',
      'sha256': 'a' * 64,
      'size': 42,
      'version': ?version,
      'notes': ?notes,
    },
  },
};

void main() {
  for (final family in ['android', 'windows', 'macos']) {
    test('$family patch order uses integer numbers and numeric core first', () {
      final ordered = [
        '0.1.13',
        '0.1.13+$family.1',
        '0.1.13+$family.2',
        '0.1.13+$family.9',
        '0.1.13+$family.10',
        '0.1.14',
      ];
      for (var i = 0; i < ordered.length; i++) {
        for (var j = 0; j < ordered.length; j++) {
          expect(compareVersions(ordered[i], ordered[j]), (i - j).sign);
        }
      }
      expect(compareVersions(' v0.1.13+$family.10 ', '0.1.13+$family.9'), 1);
      expect(compareVersions('0.1.13+$family.0', '0.1.13'), 0);
    });
  }
  test('invalid, cross-platform and ordinary build metadata', () {
    for (final value in [
      'dev',
      '0.1.13-android.1',
      '0.1.13+android.x',
      '0.1.13+windows.-1',
      '0.1.13+macos.1.x',
      '0.1.13+android',
    ]) {
      expect(compareVersions(value, value), isNull, reason: value);
    }
    expect(compareVersions('0.1.13+android.1', '0.1.13+windows.1'), isNull);
    expect(compareVersions('0.1.13+234a9d7', 'v0.1.13'), 0);
    expect(compareVersions('0.1', '0.1.0'), 0);
  });
  test('old manifest fallback and per-platform notes', () {
    final old = UpdateManifest.fromJson(manifest());
    expect(old.versionFor('android-arm64-v8a'), '0.1.13');
    expect(old.notesFor(english: true, platform: 'android-arm64-v8a'), 'Full');
    final patched = UpdateManifest.fromJson(
      manifest(
        version: '0.1.13+android.1',
        notes: {'zh': '安卓修复', 'en': 'Android fix'},
      ),
    );
    expect(patched.version, '0.1.13');
    expect(patched.versionFor('android-arm64-v8a'), '0.1.13+android.1');
    expect(patched.versionFor('windows-x64'), '0.1.13');
    expect(
      patched.notesFor(english: true, platform: 'android-arm64-v8a'),
      'Android fix',
    );
    expect(patched.notesFor(english: true, platform: 'windows-x64'), 'Full');
    final partial = UpdateManifest.fromJson(manifest(notes: {'zh': '补丁'}));
    expect(
      partial.notesFor(english: true, platform: 'android-arm64-v8a'),
      '补丁',
    );
  });
  test('malformed package fields never silently fall back', () {
    for (final value in [13, 'dev', '0.1.13+windows.1', '0.1.14+android.1']) {
      expect(
        () => UpdateManifest.fromJson(manifest(version: value)),
        throwsA(isA<UpdateException>()),
      );
    }
    for (final value in [
      'text',
      {'zh': 42},
    ]) {
      expect(
        () => UpdateManifest.fromJson(manifest(notes: value)),
        throwsA(isA<UpdateException>()),
      );
    }
  });
  test('Windows helper request keeps old-client compatible base identity', () {
    expect(windowsInstallerVersion('0.1.13+windows.10'), '0.1.13');
    expect(windowsInstallerVersion('0.1.13'), '0.1.13');
    expect(windowsInstallerVersion('0.1.13+android.1'), '0.1.13+android.1');
  });
}
