import 'dart:async';
import 'dart:io';

import 'package:bhe_core/bhe_core.dart';
import 'package:desktop/features/update/update_dialog.dart';
import 'package:desktop/core/windows_update_installer.dart';
import 'package:desktop/providers/project_state.dart';
import 'package:desktop/providers/update_provider.dart';
import 'package:desktop/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

UpdateManifest _manifest(String version) => UpdateManifest(
  version: version,
  publishedAt: '2026-10-24T08:00:00+00:00',
  notes: const {'zh': '应用内检查更新；修复多段项目审核页无法播放', 'en': 'In-app updates'},
  packages: {
    currentUpdatePlatform()!: UpdatePackage(
      url: Uri.parse('https://oss.example/BHE-v$version.dmg'),
      sha256: 'a' * 64,
      size: 400 * 1024 * 1024,
    ),
  },
);

class _FakeUpdateService extends UpdateService {
  _FakeUpdateService(this.manifest, {this.installable = false});

  UpdateManifest manifest;
  final bool installable;
  final events = <String>[];
  final session = _FakeInstallSession();
  Completer<void>? pendingPrepare;
  Object? installError;

  @override
  bool get supportsInstallation => installable;

  @override
  Future<UpdateInstallSession> prepareInstall(
    File file,
    UpdatePackage package,
    String version,
  ) async {
    events.add('prepare');
    await pendingPrepare?.future;
    if (installError != null) throw installError!;
    return session;
  }

  int fetches = 0;
  final opened = <String>[];
  Completer<File>? pendingDownload;
  void Function(int, int)? progress;

  @override
  Future<UpdateManifest> fetch() async {
    fetches++;
    return manifest;
  }

  @override
  Future<File> download(
    UpdatePackage package,
    HttpClient client,
    void Function(int received, int total) onProgress,
  ) {
    progress = onProgress;
    pendingDownload = Completer<File>();
    return pendingDownload!.future;
  }

  @override
  Future<void> open(File file) async => opened.add(file.path);
}

class _FakeInstallSession implements UpdateInstallSession {
  final events = <String>[];

  @override
  Future<void> commit() async => events.add('commit');

  @override
  Future<void> cancel() async => events.add('cancel');
}

class _IdleProject extends ProjectNotifier {
  @override
  ProjectState build() => const ProjectState();
}

class _BusyProject extends ProjectNotifier {
  @override
  ProjectState build() => const ProjectState(busy: true);
}

ProviderContainer _container(_FakeUpdateService service, String current) {
  final container = ProviderContainer(
    overrides: [
      updateServiceProvider.overrideWithValue(service),
      appVersionProvider.overrideWithValue(current),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final busy in [false, true]) {
    testWidgets('Windows installation UI respects busy state ($busy)', (
      tester,
    ) async {
      final service = _FakeUpdateService(_manifest('0.1.11'), installable: true)
        ..pendingPrepare = Completer<void>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            updateServiceProvider.overrideWithValue(service),
            appVersionProvider.overrideWithValue('0.1.10'),
            projectProvider.overrideWith(
              busy ? _BusyProject.new : _IdleProject.new,
            ),
          ],
          child: MaterialApp(
            theme: appTheme(Brightness.dark),
            home: const Scaffold(body: UpdateDialog()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('update-download')));
      await tester.pump();
      service.pendingDownload!.complete(File('/tmp/BHE.zip'));
      await tester.pumpAndSettle();
      final installButton = find.byKey(const Key('update-install'));
      expect(
        tester.widget<FilledButton>(installButton).onPressed == null,
        busy,
      );
      if (!busy) {
        await tester.tap(installButton);
        await tester.pump();
        expect(find.text('正在准备更新，请稍候…'), findsOneWidget);
        final close = find.widgetWithIcon(IconButton, LucideIcons.x);
        expect(tester.widget<IconButton>(close).onPressed, isNull);
        service.installError = StateError('fixture-preflight-failed');
        service.pendingPrepare!.complete();
        await tester.pumpAndSettle();
        expect(find.textContaining('fixture-preflight-failed'), findsOneWidget);
        expect(find.byKey(const Key('update-open')), findsOneWidget);
      }
    });
  }

  Future<ProviderContainer> readyContainer(
    _FakeUpdateService service,
    UpdateLifecycle lifecycle,
  ) async {
    final container = ProviderContainer(
      overrides: [
        updateServiceProvider.overrideWithValue(service),
        appVersionProvider.overrideWithValue('0.1.10'),
        updateLifecycleProvider.overrideWithValue(lifecycle),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(updateProvider.notifier);
    await notifier.check();
    final download = notifier.download();
    service.pendingDownload!.complete(File('/tmp/BHE.zip'));
    await download;
    return container;
  }

  test(
    'install waits for preparation and shutdown before commit and exit',
    () async {
      final service = _FakeUpdateService(_manifest('0.1.11'), installable: true)
        ..pendingPrepare = Completer<void>();
      final lifecycle = UpdateLifecycle(
        isBusy: () => false,
        prepareForExit: () async {
          expect(service.session.events, isEmpty);
          service.events.add('shutdown');
          return true;
        },
        exit: () async {
          expect(service.session.events, ['commit']);
          service.events.add('exit');
        },
        resume: () async =>
            fail('Successful install must not resume the engine'),
      );
      final container = await readyContainer(service, lifecycle);
      final notifier = container.read(updateProvider.notifier);
      final install = notifier.install();
      expect(container.read(updateProvider).status, UpdateStatus.installing);
      expect(service.events, ['prepare']);
      await notifier.install(); // Repeated clicks cannot launch another helper.
      service.pendingPrepare!.complete();
      await install;
      expect(service.events, ['prepare', 'shutdown', 'exit']);
    },
  );

  test('busy projects block install before starting the helper', () async {
    final service = _FakeUpdateService(_manifest('0.1.11'), installable: true);
    final container = await readyContainer(
      service,
      UpdateLifecycle(
        isBusy: () => true,
        prepareForExit: () async => fail('must not shut down'),
        exit: () async => fail('must not exit'),
        resume: () async => fail('must not resume'),
      ),
    );
    await container.read(updateProvider.notifier).install();
    expect(service.events, isEmpty);
    expect(container.read(updateProvider).status, UpdateStatus.ready);
  });

  for (final failure in [
    'preflight',
    'became busy',
    'save',
    'engine',
    'exit',
  ]) {
    test(
      'install failure ($failure) preserves the package and cancels replacement',
      () async {
        final service = _FakeUpdateService(
          _manifest('0.1.11'),
          installable: true,
        );
        if (failure == 'preflight') {
          service.installError = StateError('bad archive');
        }
        var busyChecks = 0;
        var exits = 0;
        var resumes = 0;
        final container = await readyContainer(
          service,
          UpdateLifecycle(
            isBusy: () => failure == 'became busy' && ++busyChecks > 1,
            prepareForExit: () async {
              if (failure == 'engine') {
                throw StateError('engine has not exited');
              }
              return failure != 'save';
            },
            exit: () async {
              exits++;
              throw StateError('window close failed');
            },
            resume: () async {
              resumes++;
            },
          ),
        );
        final notifier = container.read(updateProvider.notifier);
        await notifier.install();
        final state = container.read(updateProvider);
        expect(state.status, UpdateStatus.ready);
        expect(state.file!.path, '/tmp/BHE.zip');
        expect(state.error, isNotEmpty);
        expect(exits, failure == 'exit' ? 1 : 0);
        expect(resumes, ['save', 'engine', 'exit'].contains(failure) ? 1 : 0);
        expect(
          service.session.events,
          failure == 'preflight'
              ? []
              : failure == 'exit'
              ? ['commit', 'cancel']
              : ['cancel'],
        );
      },
    );
  }

  test(
    'platform patches use effective version for skip and later patch',
    () async {
      UpdateManifest patch(int number) {
        final platform = currentUpdatePlatform()!;
        final family = platform.split('-').first;
        return UpdateManifest(
          version: '0.1.13',
          publishedAt: '',
          notes: const {'zh': 'full'},
          packages: {
            platform: UpdatePackage(
              url: Uri.parse('https://example.invalid/patch.zip'),
              sha256: 'a' * 64,
              size: 42,
              version: '0.1.13+$family.$number',
              notes: const {'zh': 'patch'},
            ),
          },
        );
      }

      final service = _FakeUpdateService(patch(1));
      final container = _container(service, '0.1.13');
      final notifier = container.read(updateProvider.notifier);
      await notifier.check();
      expect(container.read(updateProvider).status, UpdateStatus.available);
      expect(container.read(updateProvider).targetVersion, contains('.1'));
      await notifier.skip();
      await notifier.check();
      expect(container.read(updateProvider).status, UpdateStatus.upToDate);
      await notifier.check(manual: true);
      expect(container.read(updateProvider).status, UpdateStatus.available);
      service.manifest = patch(2);
      await notifier.check();
      expect(container.read(updateProvider).status, UpdateStatus.available);
      expect(container.read(updateProvider).targetVersion, endsWith('.2'));
    },
  );

  test('auto check finds a newer version at most once a day', () async {
    final service = _FakeUpdateService(_manifest('0.1.11'));
    final container = _container(service, '0.1.10');
    final notifier = container.read(updateProvider.notifier);

    expect(await notifier.autoCheck(), isTrue);
    expect(container.read(updateProvider).status, UpdateStatus.available);
    expect(await notifier.autoCheck(), isFalse);
    expect(service.fetches, 1);
  });

  test('a development build never checks automatically', () async {
    final service = _FakeUpdateService(_manifest('0.1.11'));
    final container = _container(service, 'dev');
    expect(await container.read(updateProvider.notifier).autoCheck(), isFalse);
    expect(service.fetches, 0);
  });

  test('a skipped version stays quiet until checked by hand', () async {
    final service = _FakeUpdateService(_manifest('0.1.11'));
    final container = _container(service, '0.1.10');
    final notifier = container.read(updateProvider.notifier);
    await notifier.check();
    await notifier.skip();

    await notifier.check();
    expect(container.read(updateProvider).status, UpdateStatus.upToDate);
    await notifier.check(manual: true);
    expect(container.read(updateProvider).status, UpdateStatus.available);
  });

  test('the same version is up to date even with a build suffix', () async {
    final service = _FakeUpdateService(_manifest('0.1.10'));
    final container = _container(service, '0.1.10+234a9d7');
    await container.read(updateProvider.notifier).check(manual: true);
    expect(container.read(updateProvider).status, UpdateStatus.upToDate);
  });

  testWidgets('the dialog downloads the package and opens it', (tester) async {
    final service = _FakeUpdateService(_manifest('0.1.11'));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          updateServiceProvider.overrideWithValue(service),
          appVersionProvider.overrideWithValue('0.1.10'),
          projectProvider.overrideWith(_IdleProject.new),
        ],
        child: MaterialApp(
          theme: appTheme(Brightness.dark),
          home: const Scaffold(body: UpdateDialog()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('新版本 v0.1.11'), findsOneWidget);
    expect(find.text('· 应用内检查更新'), findsOneWidget);
    expect(find.text('· 修复多段项目审核页无法播放'), findsOneWidget);
    expect(find.textContaining('当前版本 v0.1.10 · 400 MB'), findsOneWidget);

    await tester.tap(find.byKey(const Key('update-download')));
    await tester.pump();
    service.progress!(100 * 1024 * 1024, 400 * 1024 * 1024);
    await tester.pump();
    expect(find.text('已下载 100 / 400 MB'), findsOneWidget);

    service.pendingDownload!.complete(File('/tmp/BHE-v0.1.11.dmg'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('update-open')));
    await tester.pump();
    expect(service.opened, ['/tmp/BHE-v0.1.11.dmg']);
  });
}
