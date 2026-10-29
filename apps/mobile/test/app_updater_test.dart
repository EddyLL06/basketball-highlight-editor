import 'package:bhe_core/bhe_core.dart';
import 'package:bhe_mobile/app_updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

UpdateManifest release({int patch = 1, bool old = false}) => UpdateManifest(
  version: '0.1.13',
  publishedAt: '',
  notes: const {'zh': '全量', 'en': 'Full'},
  packages: {
    'android-arm64-v8a': UpdatePackage(
      url: Uri.parse('https://example.invalid/app.apk'),
      sha256: 'a' * 64,
      size: 42,
      version: old ? null : '0.1.13+android.$patch',
      notes: old ? null : const {'zh': '安卓修复', 'en': 'Android fix'},
    ),
  },
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'patch checks, notes, skipping and manual checks use target platform',
    () async {
      var latest = release();
      final updater = AppUpdater(
        currentVersion: '0.1.13',
        platform: 'android-arm64-v8a',
        fetch: () async => latest,
      );
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.status, UpdateStatus.available);
      expect(updater.targetVersion, '0.1.13+android.1');
      expect(updater.notesFor(english: true), 'Android fix');
      await updater.skip();
      await updater.check();
      expect(updater.status, UpdateStatus.upToDate);
      await updater.check(manual: true);
      expect(updater.status, UpdateStatus.available);
      latest = release(patch: 2);
      await updater.check();
      expect(updater.status, UpdateStatus.available);
      expect(updater.targetVersion, '0.1.13+android.2');
    },
  );
  test('other platform and same patch remain quiet', () async {
    for (final platform in ['windows-x64', 'android-arm64-v8a']) {
      final updater = AppUpdater(
        currentVersion: '0.1.13+android.1',
        platform: platform,
        fetch: () async => release(),
      );
      await updater.check();
      expect(updater.status, UpdateStatus.upToDate);
      updater.dispose();
    }
  });
  test(
    'old manifest still upgrades and old skipped base does not hide a patch',
    () async {
      SharedPreferences.setMockInitialValues({
        'bhe.update-skipped-version': '0.1.13',
      });
      final patched = AppUpdater(
        currentVersion: '0.1.13',
        platform: 'android-arm64-v8a',
        fetch: () async => release(),
      );
      await patched.check();
      expect(patched.status, UpdateStatus.available);
      patched.dispose();
      final old = AppUpdater(
        currentVersion: '0.1.12',
        platform: 'android-arm64-v8a',
        fetch: () async => release(old: true),
      );
      await old.check(manual: true);
      expect(old.status, UpdateStatus.available);
      expect(old.targetVersion, '0.1.13');
      expect(old.notesFor(english: true), 'Full');
      old.dispose();
    },
  );
  test('automatic check rate and dev behavior remain unchanged', () async {
    var fetches = 0;
    Future<UpdateManifest> fetch() async {
      fetches++;
      return release();
    }

    final updater = AppUpdater(
      currentVersion: '0.1.13',
      platform: 'android-arm64-v8a',
      fetch: fetch,
    );
    expect(await updater.autoCheck(), isTrue);
    expect(await updater.autoCheck(), isFalse);
    final dev = AppUpdater(
      currentVersion: 'dev',
      platform: 'android-arm64-v8a',
      fetch: fetch,
    );
    expect(await dev.autoCheck(), isFalse);
    expect(fetches, 1);
    updater.dispose();
    dev.dispose();
  });
}
