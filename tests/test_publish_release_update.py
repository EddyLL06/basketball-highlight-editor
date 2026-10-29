import copy
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

import build_update_manifest as manifest
import publish_release_update as publisher
from tests.platform_patch_support import ReleaseFixture


@pytest.fixture
def offline(tmp_path, monkeypatch):
    # Never inherit production credentials or accidentally construct network transport.
    for key in list(os.environ):
        if key.startswith(('ALIYUN_', 'OSS_', 'GH_TOKEN', 'GITHUB_TOKEN', 'BHE_UPDATE_SIGNING')):
            monkeypatch.delenv(key)
    def forbidden(*_args, **_kwargs):
        raise AssertionError('Offline tests must never use a network transport')
    monkeypatch.setattr(publisher, 'OssStore', forbidden)
    release = ReleaseFixture(tmp_path / 'fixture')
    store = publisher.DirectoryStore(tmp_path / 'fake-oss')
    return release, store


def seed(release, store, previous=None):
    path, signature = release.signed_previous(previous)
    store.upload(path, 'releases/latest.json')
    store.upload(signature, 'releases/latest.json.sig')
    for platform, suffix in manifest.PLATFORMS.items():
        key = 'android/latest.apk' if platform.startswith('android') else f'releases/BHE-{platform}-latest{suffix}'
        file = release.root / 'old-alias'
        file.write_text('old ' + platform)
        store.upload(file, key)
        store.upload(file, key + '.sha256')


def command(release, store, tag, *, suffix=''):
    if '| ' + tag + ' |' not in release.zh.read_text(): release.notes(tag)
    assets = release.assets(tag)
    base, family, _ = manifest.release_parts(tag)
    work = release.root / ('work-' + tag + suffix)
    args = ['--store-dir', str(store.root), '--tag', tag, '--platform', family or 'all',
            '--assets-dir', str(assets), '--base-url', 'https://example.invalid/releases',
            '--android-base-url', 'https://android.example.invalid/releases',
            '--readme-zh', str(release.zh), '--readme-en', str(release.en),
            '--public-key', str(release.public), '--signing-key', str(release.key), '--work-dir', str(work)]
    return args, work


def read(store, release):
    return manifest.read_signed_manifest(store.path('releases/latest.json'), store.path('releases/latest.json.sig'), release.public)


def snapshot(store):
    return {str(p.relative_to(store.root)): p.read_bytes() for p in store.root.rglob('*') if p.is_file()}


def tree_snapshot(store):
    return {str(p.relative_to(store.root)): p.read_bytes() if p.is_file() else None
            for p in store.root.rglob('*')}


@pytest.mark.parametrize('tag', ['v0.1.14', 'v0.1.13-android.1', 'v0.1.13-macos.1'])
def test_dry_run_verifies_and_lists_exact_writes_without_touching_store(offline, tag, monkeypatch):
    release, store = offline
    seed(release, store)
    args, work = command(release, store, tag)
    assets = Path(args[args.index('--assets-dir') + 1])
    # Existing identical immutable files are checked but will not be uploaded.
    existing = next(p for p in assets.iterdir() if p.suffix != '.sha256')
    store.upload(existing, 'releases/' + existing.name)
    before = tree_snapshot(store)
    step_summary = release.root / 'step-summary.md'
    monkeypatch.setenv('GITHUB_STEP_SUMMARY', str(step_summary))
    def forbidden(*_args, **_kwargs):
        raise AssertionError('dry-run must not upload')
    monkeypatch.setattr(publisher.DirectoryStore, 'upload', forbidden)
    assert publisher.main([*args, '--dry-run']) == 0
    assert tree_snapshot(store) == before
    summary = json.loads((work / 'publish-summary.json').read_text())
    assert summary['status'] == 'dry-run-ok'
    assert summary['stage'] == 'dry-run-complete'
    candidate = manifest.read_signed_manifest(work / 'candidate.json', work / 'candidate.json.sig', release.public)
    assert candidate['version'] == summary['version']
    expected = {f'releases/{p.name}' for p in assets.iterdir() if p.name != existing.name}
    for platform, entry in summary['packages'].items():
        name = Path(entry['url']).name
        alias = ('android/latest.apk' if platform.startswith('android-') else
                 f'releases/BHE-{platform}-latest{Path(name).suffix}')
        expected.update((alias, alias + '.sha256'))
    expected.update(('releases/latest.json.sig', 'releases/latest.json'))
    assert len(summary['would_upload']) == len(expected)
    assert set(summary['would_upload']) == expected
    assert '未写入 OSS 发布对象；Actions 产物中保存演练文件' in step_summary.read_text()
    assert summary['previous_verified'] and summary['candidate_verified']
    assert all(key in step_summary.read_text() for key in expected)


@pytest.mark.parametrize('fault', ['missing-body', 'missing-signature', 'signature', 'signing-key',
                                   'immutable-conflict', 'downgrade'])
def test_dry_run_has_same_preflight_failures_as_publish(offline, fault, monkeypatch):
    release, store = offline
    seed(release, store)
    tag = 'v0.1.12' if fault == 'downgrade' else 'v0.1.13-android.1'
    args, work = command(release, store, tag)
    if fault == 'missing-body': store.path('releases/latest.json').unlink()
    elif fault == 'missing-signature': store.path('releases/latest.json.sig').unlink()
    elif fault == 'signature': store.path('releases/latest.json.sig').write_bytes(b'bad')
    elif fault == 'signing-key':
        other = ReleaseFixture(release.root / 'other')
        args[args.index('--signing-key') + 1] = str(other.key)
    elif fault == 'immutable-conflict':
        name = next(Path(args[args.index('--assets-dir') + 1]).glob('*.apk')).name
        store.path('releases/' + name).write_bytes(b'conflict')
    before = tree_snapshot(store)
    def forbidden(*_args, **_kwargs): raise AssertionError('preflight must never upload')
    monkeypatch.setattr(publisher.DirectoryStore, 'upload', forbidden)
    assert publisher.main(args) == 1
    normal = json.loads((work / 'publish-summary.json').read_text())
    assert tree_snapshot(store) == before
    dry_work = work.with_name(work.name + '-dry')
    args[args.index('--work-dir') + 1] = str(dry_work)
    assert publisher.main([*args, '--dry-run']) == 1
    rehearsal = json.loads((dry_work / 'publish-summary.json').read_text())
    assert (rehearsal['status'], rehearsal['stage'], rehearsal['error']) == (normal['status'], normal['stage'], normal['error'])
    assert tree_snapshot(store) == before


def test_dry_run_rejects_work_dir_inside_store_before_writing(offline):
    release, store = offline
    seed(release, store)
    args, _ = command(release, store, 'v0.1.13-android.1')
    args[args.index('--work-dir') + 1] = str(store.root / 'work')
    before = tree_snapshot(store)
    with pytest.raises(SystemExit):
        publisher.main([*args, '--dry-run'])
    assert tree_snapshot(store) == before


def test_dry_run_rejects_existing_symlink_target_and_directory_store_uses_exclusive_create(offline):
    release, store = offline
    seed(release, store)
    args, work = command(release, store, 'v0.1.13-android.1')
    probe = store.path('probe-object')
    probe.write_bytes(b'unchanged')
    work.mkdir()
    (work / 'previous.json').symlink_to(probe)
    before = tree_snapshot(store)
    with pytest.raises(SystemExit):
        publisher.main([*args, '--dry-run'])
    assert tree_snapshot(store) == before
    store.exclusive_download = True
    with pytest.raises(FileExistsError):
        store.download('releases/latest.json', work / 'previous.json')
    assert tree_snapshot(store) == before


def test_dry_run_rejects_summary_symlink_resolved_inside_store(offline, monkeypatch):
    release, store = offline
    seed(release, store)
    args, work = command(release, store, 'v0.1.13-android.1')
    probe = store.path('report.md')
    probe.write_bytes(b'unchanged')
    link = release.root / 'summary-link'
    link.symlink_to(probe)
    monkeypatch.setenv('GITHUB_STEP_SUMMARY', str(link))
    before = tree_snapshot(store)
    with pytest.raises(SystemExit):
        publisher.main([*args, '--dry-run'])
    assert not work.exists()
    assert tree_snapshot(store) == before


@pytest.mark.parametrize('mode', ['direct', 'symlink', 'hardlink'])
def test_dry_run_rejects_store_summary_aliases(offline, monkeypatch, mode):
    release, store = offline
    seed(release, store)
    args, work = command(release, store, 'v0.1.13-android.1')
    probe = store.path('report.md')
    probe.write_bytes(b'private existing object')
    alias = probe if mode == 'direct' else release.root / 'summary-alias'
    if mode == 'symlink': alias.symlink_to(probe)
    if mode == 'hardlink': os.link(probe, alias)
    monkeypatch.setenv('GITHUB_STEP_SUMMARY', str(alias))
    before = tree_snapshot(store)
    with pytest.raises(SystemExit): publisher.main([*args, '--dry-run'])
    assert not work.exists()
    assert tree_snapshot(store) == before


def test_oss_dry_run_also_rejects_hardlinked_summary(tmp_path, monkeypatch):
    release = ReleaseFixture(tmp_path / 'fixture')
    store = publisher.DirectoryStore(tmp_path / 'fake-oss')
    seed(release, store)
    args, work = command(release, store, 'v0.1.13-android.1')
    args[:2] = ['--oss-root', 'oss://fake']
    probe = store.path('report.md')
    probe.write_bytes(b'unchanged')
    alias = release.root / 'summary-link'
    os.link(probe, alias)
    monkeypatch.setenv('GITHUB_STEP_SUMMARY', str(alias))
    before = tree_snapshot(store)
    with pytest.raises(SystemExit): publisher.main([*args, '--dry-run'])
    assert not work.exists() and tree_snapshot(store) == before


def test_full_013_publish_keeps_four_platforms_notes_signature_and_website_aliases(offline):
    release, store = offline
    old = copy.deepcopy(release.previous)
    old['version'] = '0.1.12'
    for entry in old['packages'].values(): entry['version'] = '0.1.12'
    seed(release, store, old)
    args, work = command(release, store, 'v0.1.13')
    assert publisher.main(args) == 0
    result = read(store, release)
    assert result['version'] == '0.1.13'
    assert result['notes'] == {'zh': '修复 0.1.13', 'en': 'Fix 0.1.13'}
    assert set(result['packages']) == set(manifest.PLATFORMS)
    for platform, entry in result['packages'].items():
        assert entry['version'] == '0.1.13'
        assert entry['notes'] == result['notes']
        source = Path(args[args.index('--assets-dir') + 1]) / Path(entry['url']).name
        key = 'android/latest.apk' if platform.startswith('android') else f'releases/BHE-{platform}-latest{source.suffix}'
        assert store.path(key).read_bytes() == source.read_bytes()
    summary = json.loads((work / 'publish-summary.json').read_text())
    assert summary['status'] == 'success'
    assert len(summary['packages']) == 4


def test_two_platform_patches_preserve_previous_patch_and_other_aliases(offline):
    release, store = offline
    seed(release, store)
    args, work = command(release, store, 'v0.1.13-android.1')
    before = snapshot(store)
    assert publisher.main(args) == 0
    android = read(store, release)['packages']['android-arm64-v8a']
    for key, content in before.items():
        if key not in ('releases/latest.json', 'releases/latest.json.sig', 'android/latest.apk', 'android/latest.apk.sha256'):
            assert store.path(key).read_bytes() == content
    args, _ = command(release, store, 'v0.1.13-windows.1')
    assert publisher.main(args) == 0
    current = read(store, release)
    assert current['version'] == '0.1.13'
    assert current['packages']['android-arm64-v8a'] == android
    assert current['packages']['windows-x64']['version'] == '0.1.13+windows.1'


def test_mac_patch_publishes_both_architectures(offline):
    release, store = offline
    seed(release, store)
    args, work = command(release, store, 'v0.1.13-macos.1')
    assert publisher.main(args) == 0
    summary = json.loads((work / 'publish-summary.json').read_text())
    assert set(summary['packages']) == set(manifest.FAMILIES['macos'])


@pytest.mark.parametrize('fault', ['missing-body', 'missing-signature', 'signature', 'signing-key', 'immutable-conflict', 'wrong-platform'])
def test_validation_failure_never_uploads_any_object(offline, fault, monkeypatch):
    release, store = offline
    seed(release, store)
    args, work = command(release, store, 'v0.1.13-android.1')
    if fault == 'missing-body': store.path('releases/latest.json').unlink()
    elif fault == 'missing-signature': store.path('releases/latest.json.sig').unlink()
    elif fault == 'signature': store.path('releases/latest.json.sig').write_bytes(b'bad')
    elif fault == 'signing-key':
        other = ReleaseFixture(release.root / 'other')
        args[args.index('--signing-key') + 1] = str(other.key)
    elif fault == 'immutable-conflict':
        name = next((release.root / 'assets-0.1.13-android.1').glob('*.apk')).name
        store.path('releases').mkdir(exist_ok=True)
        store.path('releases/' + name).write_bytes(b'previous immutable contents')
    elif fault == 'wrong-platform': args[args.index('--platform') + 1] = 'all'
    before = snapshot(store)
    def forbidden(*_args, **_kwargs): raise AssertionError('Validation must finish before writes')
    monkeypatch.setattr(publisher.DirectoryStore, 'upload', forbidden)
    assert publisher.main(args) == 1
    assert snapshot(store) == before
    assert json.loads((work / 'publish-summary.json').read_text())['status'] == 'failed'


@pytest.mark.parametrize('stage', ['upload-versioned', 'upload-alias', 'upload-alias-checksum', 'upload-manifest-signature', 'upload-manifest', 'verify-published'])
def test_each_upload_or_readback_failure_records_stage_and_stops(offline, stage, monkeypatch):
    release, store = offline
    seed(release, store)
    args, work = command(release, store, 'v0.1.13-android.1')
    real_stage = publisher.Summary.stage
    def inject(self, name, key=None):
        real_stage(self, name, key)
        if name == stage: raise OSError('injected offline failure')
    monkeypatch.setattr(publisher.Summary, 'stage', inject)
    assert publisher.main(args) == 1
    summary = json.loads((work / 'publish-summary.json').read_text())
    assert summary['stage'] == stage and summary['status'] == 'failed'
    assert summary['events'][-1]['stage'] == stage
    assert all('windows' not in e.get('object', '') and 'macos' not in e.get('object', '') for e in summary['events'])
    # Pair interruption is visible, never reported as success or silently repaired.
    if stage == 'upload-manifest':
        with pytest.raises(ValueError, match='签名'): read(store, release)


def test_new_full_release_resets_patches_and_rejects_old_base_or_old_full_replay(offline):
    release, store = offline
    seed(release, store)
    args, _ = command(release, store, 'v0.1.13-android.2')
    assert publisher.main(args) == 0
    args, _ = command(release, store, 'v0.1.13')
    assert publisher.main(args) == 1
    args, _ = command(release, store, 'v0.1.14')
    assert publisher.main(args) == 0
    result = read(store, release)
    assert result['version'] == '0.1.14'
    assert all(p['version'] == '0.1.14' for p in result['packages'].values())
    before = snapshot(store)
    args, _ = command(release, store, 'v0.1.13-windows.3')
    assert publisher.main(args) == 1
    assert snapshot(store) == before


def test_cancelled_script_retains_last_stage_and_cancellation_summary(offline, monkeypatch):
    release, store = offline
    seed(release, store)
    args, work = command(release, store, 'v0.1.13-android.1')
    step_summary = release.root / 'step-summary.md'
    monkeypatch.setenv('GITHUB_STEP_SUMMARY', str(step_summary))
    def cancel(*_args, **_kwargs): raise publisher.PublishCancelled('cancelled test')
    monkeypatch.setattr(publisher.DirectoryStore, 'download', cancel)
    assert publisher.main(args) == 130
    assert json.loads((work / 'publish-summary.json').read_text())['status'] == 'cancelled'
    assert 'cancelled' in step_summary.read_text()


def test_offline_command_line_entry_runs_without_network_or_cloud_environment(offline):
    release, store = offline
    seed(release, store)
    args, work = command(release, store, 'v0.1.13-android.1')
    root = Path(__file__).resolve().parents[1]
    env = {k: os.environ[k] for k in ('PATH', 'TMPDIR', 'SYSTEMROOT') if k in os.environ}
    subprocess.run([sys.executable, str(root / 'scripts/publish_release_update.py'), *args], check=True, env=env, capture_output=True)
    assert json.loads((work / 'publish-summary.json').read_text())['status'] == 'success'
    assert read(store, release)['packages']['android-arm64-v8a']['version'].endswith('android.1')


@pytest.mark.parametrize('fault', ['ok', 'missing', '403', '500', 'timeout', 'signature', 'signing-key',
                                   'bad-json', 'bad-checksum', 'wrong-platform', 'cancel'])
def test_oss_dry_run_only_get_and_never_calls_ossutil(tmp_path, monkeypatch, fault):
    import io
    from urllib.error import HTTPError
    from urllib.parse import urlparse

    release = ReleaseFixture(tmp_path / 'fixture')
    store = publisher.DirectoryStore(tmp_path / 'fake-oss')
    seed(release, store)
    args, work = command(release, store, 'v0.1.13-android.1')
    if fault == 'signature': store.path('releases/latest.json.sig').write_bytes(b'bad')
    if fault == 'bad-json':
        old = release.root / 'broken.json'
        old.write_bytes(b'{broken json')
        store.upload(old, 'releases/latest.json')
        store.upload(release.sign(old), 'releases/latest.json.sig')
    if fault == 'signing-key':
        other = ReleaseFixture(release.root / 'other')
        args[args.index('--signing-key') + 1] = str(other.key)
    if fault == 'bad-checksum':
        assets = Path(args[args.index('--assets-dir') + 1])
        next(assets.glob('*.sha256')).write_text('bad checksum')
    if fault == 'wrong-platform': args[args.index('--platform') + 1] = 'all'
    args[:2] = ['--oss-root', 'oss://fake']
    args += ['--dry-run']
    monkeypatch.setenv('GITHUB_ACTIONS', 'true')
    calls = []
    def fake_urlopen(request, timeout):
        assert request.get_method() == 'GET' and timeout == 60
        calls.append(request.full_url)
        name = urlparse(request.full_url).path.rsplit('/', 1)[-1]
        if name == 'latest.json':
            if fault in ('missing', '403', '500'):
                code = 404 if fault == 'missing' else int(fault)
                raise HTTPError(request.full_url, code, 'fake', {}, None)
            if fault == 'timeout': raise TimeoutError('fake timeout')
            if fault == 'cancel': raise publisher.PublishCancelled('fake cancellation')
        source = store.path('releases/' + name)
        if not source.is_file(): raise HTTPError(request.full_url, 404, 'fake', {}, None)
        return io.BytesIO(source.read_bytes())
    monkeypatch.setattr(publisher.urllib.request, 'urlopen', fake_urlopen)
    real_run = subprocess.run
    commands = []
    def fake_run(command, *a, **kw):
        commands.append(command)
        assert command[0] == 'openssl', command
        return real_run(command, *a, **kw)
    monkeypatch.setattr(publisher.subprocess, 'run', fake_run)
    before = tree_snapshot(store)
    result = publisher.main(args)
    assert result == (0 if fault == 'ok' else 130 if fault == 'cancel' else 1)
    summary = json.loads((work / 'publish-summary.json').read_text())
    assert summary['status'] == ('dry-run-ok' if fault == 'ok' else 'cancelled' if fault == 'cancel' else 'failed')
    assert summary['previous_verified'] == (fault in ('ok', 'signing-key', 'bad-checksum'))
    assert summary['candidate_verified'] == (fault == 'ok')
    assert tree_snapshot(store) == before
    assert all(command[0] == 'openssl' for command in commands)
    assert calls or fault == 'wrong-platform'


def test_real_oss_publish_still_requires_config(tmp_path, monkeypatch):
    release = ReleaseFixture(tmp_path / 'fixture')
    store = publisher.DirectoryStore(tmp_path / 'fake')
    args, work = command(release, store, 'v0.1.13-android.1')
    args[:2] = ['--oss-root', 'oss://fake']
    monkeypatch.setenv('GITHUB_ACTIONS', 'true')
    assert publisher.main(args) == 1
    assert json.loads((work / 'publish-summary.json').read_text())['status'] == 'failed'
