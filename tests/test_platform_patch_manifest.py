import base64
import copy
import json
import re
import zipfile
from pathlib import Path

import pytest

import build_update_manifest as manifest
from tests.platform_patch_support import ReleaseFixture


@pytest.fixture
def release(tmp_path):
    return ReleaseFixture(tmp_path)


@pytest.mark.parametrize('family', ['android', 'macos', 'windows'])
def test_patch_changes_only_target_semantics_and_preserves_key_order(release, family):
    old = copy.deepcopy(release.previous)
    result = release.merge(f'v0.1.13-{family}.1')
    assert result['version'] == old['version']
    assert result['notes'] == old['notes']
    assert result['unknown'] == old['unknown']
    assert list(result) == list(old)
    assert list(result['packages']) == list(old['packages'])
    for platform, entry in old['packages'].items():
        if platform in manifest.FAMILIES[family]:
            assert result['packages'][platform]['version'] == f'0.1.13+{family}.1'
            assert result['packages'][platform]['notes']['en'].startswith('Fix ')
            if 'extension' in entry:
                assert result['packages'][platform]['extension'] == entry['extension']
        else:
            assert result['packages'][platform] == entry
    assert release.previous == old


def test_legacy_manifest_and_signed_cli_merge(release):
    for entry in release.previous['packages'].values():
        entry.pop('version'); entry.pop('notes')
    previous, signature = release.signed_previous()
    release.notes('v0.1.13-android.1')
    assets = release.assets('v0.1.13-android.1')
    output = release.root / 'new.json'
    manifest.main(['--tag', 'v0.1.13-android.1', '--assets-dir', str(assets), '--base-url', 'https://example.invalid/releases',
                   '--readme-zh', str(release.zh), '--readme-en', str(release.en), '--previous-manifest', str(previous),
                   '--previous-signature', str(signature), '--public-key', str(release.public), '--out', str(output)])
    parsed = json.loads(output.read_text())
    assert parsed['packages']['android-arm64-v8a']['version'] == '0.1.13+android.1'
    assert output.read_text().endswith('\n')
    assert '\\u' not in output.read_text()
    manifest.verify_signature(output, release.sign(output), release.public)


@pytest.mark.parametrize('fault', ['missing-manifest', 'missing-signature', 'tampered-body', 'tampered-signature', 'wrong-public', 'duplicate-key'])
def test_old_manifest_must_be_present_signed_and_strict(release, tmp_path, fault):
    previous, signature = release.signed_previous()
    public = release.public
    if fault == 'missing-manifest': previous.unlink()
    elif fault == 'missing-signature': signature.unlink()
    elif fault == 'tampered-body': previous.write_bytes(previous.read_bytes() + b' ')
    elif fault == 'tampered-signature': signature.write_bytes(b'bad')
    elif fault == 'wrong-public': public = ReleaseFixture(tmp_path / 'other').public
    elif fault == 'duplicate-key':
        previous.write_text('{"version":"0.1.13","version":"9.9.9"}')
        release.sign(previous)
    with pytest.raises(ValueError):
        manifest.read_signed_manifest(previous, signature, public)


def test_signature_verification_precedes_json_parsing(release):
    body, signature = release.signed_previous()
    body.write_text('not JSON')
    with pytest.raises(ValueError, match='签名'):
        manifest.read_signed_manifest(body, signature, release.public)


def test_downgrades_conflicting_retries_and_old_base_rejected(release):
    first = release.merge('v0.1.13-android.10')
    release.notes('v0.1.13-android.9')
    with pytest.raises(ValueError, match='覆盖'):
        manifest.merge_manifest(first, 'v0.1.13-android.9', release.assets('v0.1.13-android.9'), 'https://example.invalid/releases', release.zh, release.en)
    retry = manifest.merge_manifest(first, 'v0.1.13-android.10', release.assets('v0.1.13-android.10'), 'https://example.invalid/releases', release.zh, release.en, 'https://android.example.invalid/releases')
    assert retry == first
    with pytest.raises(ValueError, match='同版本'):
        manifest.merge_manifest(first, 'v0.1.13-android.10', release.assets('v0.1.13-android.10'), 'https://changed.invalid', release.zh, release.en)
    with pytest.raises(ValueError, match='当前完整版本'):
        release.merge('v0.1.12-android.1')
    with pytest.raises(ValueError, match='当前完整版本'):
        release.merge('v0.1.14-android.1')


def test_mac_requires_both_architectures_and_exact_package_names(release):
    tag = 'v0.1.13-macos.1'
    release.notes(tag)
    assets = release.assets(tag)
    next(p for p in assets.glob('*x86_64*.dmg')).unlink()
    with pytest.raises(ValueError, match='架构'):
        manifest.merge_manifest(release.previous, tag, assets, 'https://example.invalid', release.zh, release.en)
    with pytest.raises(SystemExit, match='没有'):
        manifest.package_entries(assets, '0.1.13-macos.10', 'https://example.invalid', 'https://example.invalid')


@pytest.mark.parametrize('fault', ['checksum', 'foreign', 'notes', 'empty', 'duplicate'])
def test_invalid_assets_and_missing_bilingual_notes_rejected(release, fault):
    tag = 'v0.1.13-android.1'
    release.notes(tag)
    assets = release.assets(tag)
    apk = next(assets.glob('*.apk'))
    if fault == 'checksum': apk.with_name(apk.name + '.sha256').write_text('bad')
    elif fault == 'foreign': (assets / 'BHE-windows-x64-v0.1.13-windows.1.zip').write_bytes(b'zip')
    elif fault == 'notes': release.en.write_text('')
    elif fault == 'empty': apk.write_bytes(b'')
    elif fault == 'duplicate': (assets / apk.name.replace('-debug-signed', '')).write_bytes(b'apk')
    with pytest.raises((ValueError, SystemExit)):
        manifest.merge_manifest(release.previous, tag, assets, 'https://example.invalid', release.zh, release.en)


def test_unsafe_windows_patch_is_rejected_before_old_client_can_download_it(release):
    tag = 'v0.1.13-windows.1'
    release.notes(tag)
    assets = release.assets(tag)
    archive = next(assets.glob('*.zip'))
    # Reproduce the previously-shipped strict helper's incompatible metadata.
    with zipfile.ZipFile(archive, 'w') as package:
        package.writestr('BHE/bhe-release.json', json.dumps({'schema': 1, 'version': '0.1.13-windows.1'}))
    release.checksum(archive)
    with pytest.raises(ValueError, match='旧客户端'):
        manifest.merge_manifest(release.previous, tag, assets, 'https://example.invalid', release.zh, release.en)
    # New inventory keeps the exact base required by that helper, records the patch separately.
    release.assets(tag)
    result = manifest.merge_manifest(release.previous, tag, assets, 'https://example.invalid', release.zh, release.en)
    with zipfile.ZipFile(archive) as package:
        inventory = json.loads(package.read('BHE/bhe-release.json'))
    assert inventory['version'] == result['version'] == '0.1.13'
    assert inventory['release_version'] == '0.1.13-windows.1'
    assert result['packages']['windows-x64']['version'] == '0.1.13+windows.1'


def test_trusted_public_key_matches_client_constant():
    root = Path(__file__).resolve().parents[1]
    source = (root / 'packages/bhe_core/lib/src/app_update.dart').read_text()
    raw = base64.b64decode(re.search(r"defaultValue: '([A-Za-z0-9+/=]{44})'", source)[1])
    pem = manifest.PUBLIC_KEY.read_text().splitlines()
    assert base64.b64decode(''.join(pem[1:-1])) == bytes.fromhex('302a300506032b6570032100') + raw


def test_strict_json_rejects_duplicate_nested_fields_and_nonfinite_values():
    for body in ['{"a":{"b":1,"b":2}}', '{"a":NaN}', '[]']:
        with pytest.raises(ValueError): manifest.strict_json(body)


@pytest.mark.parametrize('value', ['', 0, False, [], {}])
def test_present_invalid_package_version_is_not_a_fallback(release, value):
    release.previous['packages']['android-arm64-v8a']['version'] = value
    with pytest.raises(ValueError): manifest.validate_manifest(release.previous)


@pytest.mark.parametrize('separator', ['/', '\\'])
def test_windows_inventory_accepts_both_zip_separators(release, separator):
    tag = 'v0.1.13-windows.1'
    release.notes(tag)
    assets = release.assets(tag)
    archive = next(assets.glob('*.zip'))
    with zipfile.ZipFile(archive, 'w') as package:
        package.writestr(separator.join(['BHE', 'bhe-release.json']), json.dumps({
            'schema': 1, 'version': '0.1.13', 'release_version': '0.1.13-windows.1',
        }))
    release.checksum(archive)
    entries = manifest.package_entries(assets, tag[1:], 'https://example.invalid', 'https://example.invalid')
    manifest.validate_assets(assets, tag, 'windows', entries)


@pytest.mark.parametrize('names', [
    [],
    ['BHE/bhe-release.json', 'BHE/bhe-release.json'],
    ['BHE/bhe-release.json', r'BHE\bhe-release.json'],
    ['BHE/bhe-release.json', r'BHE\BHE-RELEASE.JSON'],
    ['BHE/BHE-RELEASE.JSON'],
    ['BHE/bhe-release.json/'],
    ['BHE/bhe-release.json', 'BHE\\bhe-release.json\\'],
])
def test_windows_inventory_rejects_missing_and_equivalent_duplicates(release, names):
    import warnings

    tag = 'v0.1.13-windows.1'
    assets = release.assets(tag)
    archive = next(assets.glob('*.zip'))
    with warnings.catch_warnings():
        warnings.simplefilter('ignore', UserWarning)
        with zipfile.ZipFile(archive, 'w') as package:
            for name in names:
                package.writestr(name, json.dumps({
                    'schema': 1, 'version': '0.1.13', 'release_version': '0.1.13-windows.1',
                }))
    release.checksum(archive)
    entries = manifest.package_entries(assets, tag[1:], 'https://example.invalid', 'https://example.invalid')
    with pytest.raises(ValueError, match='Windows 文件清单缺失或重复'):
        manifest.validate_assets(assets, tag, 'windows', entries)
