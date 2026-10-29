#!/usr/bin/env python3
"""Generate full update manifests or merge verified platform patches locally.

Notes always come from exact version rows in both READMEs. Transport and signing
are handled by the publishing entry point; this module never contacts OSS.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PUBLIC_KEY = ROOT / 'scripts/update_public_key.pem'
PLATFORMS = {
    'macos-arm64': '.dmg', 'macos-x86_64': '.dmg',
    'windows-x64': '.zip', 'android-arm64-v8a': '.apk',
}
FAMILIES = {family: tuple(p for p in PLATFORMS if p.startswith(family + '-'))
            for family in ('macos', 'windows', 'android')}


def release_parts(tag: str) -> tuple[str, str | None, int]:
    if not isinstance(tag, str):
        raise ValueError('版本必须为字符串')
    match = re.fullmatch(r'v?([0-9]+\.[0-9]+\.[0-9]+)(?:-(macos|windows|android)\.([1-9][0-9]*))?', tag)
    if not match:
        raise ValueError(f'不支持生产更新版本：{tag}')
    return match[1], match[2], int(match[3] or 0)


def version_parts(version: str) -> tuple[tuple[int, ...], str | None, int]:
    base, family, patch = release_parts(version.replace('+', '-'))
    return tuple(map(int, base.split('.'))), family, patch


def strict_json(body: bytes | str) -> dict:
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError(f'JSON 重复键：{key}')
            result[key] = value
        return result

    def invalid_constant(value):
        raise ValueError(f'JSON 非有限数字：{value}')

    value = json.loads(body, object_pairs_hook=pairs, parse_constant=invalid_constant)
    if not isinstance(value, dict):
        raise ValueError('更新清单必须为对象')
    return value


def dump_manifest(manifest: dict, path: Path) -> None:
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, allow_nan=False) + '\n', encoding='utf-8')


def verify_signature(manifest: Path, signature: Path, public_key: Path) -> None:
    if not all(path.is_file() for path in (manifest, signature, public_key)):
        raise ValueError('旧清单、签名或受信公钥缺失，禁止从零合并')
    result = subprocess.run([
        'openssl', 'pkeyutl', '-verify', '-pubin', '-inkey', str(public_key),
        '-rawin', '-in', str(manifest), '-sigfile', str(signature),
    ], capture_output=True)
    if result.returncode:
        raise ValueError('更新清单签名校验失败')


def validate_manifest(manifest: dict) -> None:
    version = manifest.get('version')
    if not isinstance(version, str) or release_parts(version)[1] is not None:
        raise ValueError('顶层版本必须为完整数字版本')
    packages = manifest.get('packages')
    if not isinstance(packages, dict) or not set(PLATFORMS).issubset(packages):
        raise ValueError('清单缺少完整的平台条目')
    if not isinstance(manifest.get('published_at'), str):
        raise ValueError('清单缺少发布时间')
    if not isinstance(manifest.get('notes'), dict) or any(
            not isinstance(k, str) or not isinstance(v, str) for k, v in manifest['notes'].items()):
        raise ValueError('清单缺少更新说明')
    for key, entry in packages.items():
        if key not in PLATFORMS:
            continue  # Preserve extensions for platforms this release does not own.
        if not isinstance(entry, dict):
            raise ValueError(f'{key} 包条目无效')
        if not re.fullmatch(r'https?://[^\s]+', str(entry.get('url', ''))):
            raise ValueError(f'{key} 下载地址无效')
        if not re.fullmatch(r'[0-9a-fA-F]{64}', str(entry.get('sha256', ''))):
            raise ValueError(f'{key} 摘要无效')
        if type(entry.get('size')) is not int or entry['size'] <= 0:
            raise ValueError(f'{key} 大小无效')
        effective = entry.get('version')
        if effective is None:
            effective = version
        elif not isinstance(effective, str) or not effective:
            raise ValueError(f'{key} 平台版本无效')
        numbers, family, _ = version_parts(effective)
        if numbers != version_parts(version)[0] or (family and family != key.split('-')[0]):
            raise ValueError(f'{key} 平台版本不匹配')
        notes = entry.get('notes')
        if notes is not None and (not isinstance(notes, dict) or
                                  any(not isinstance(k, str) or not isinstance(v, str) for k, v in notes.items())):
            raise ValueError(f'{key} 说明无效')


def read_signed_manifest(manifest: Path, signature: Path, public_key: Path = PUBLIC_KEY) -> dict:
    # Verify the original bytes, never a reserialized version of untrusted JSON.
    verify_signature(manifest, signature, public_key)
    result = strict_json(manifest.read_bytes())
    validate_manifest(result)
    return result


def release_notes(readme: Path, version: str) -> str:
    prefix = f'| v{version} |'
    matches = [line for line in readme.read_text(encoding='utf-8').splitlines() if line.startswith(prefix)]
    if len(matches) == 1:
        cells = [cell.strip() for cell in matches[0].strip().strip('|').split('|')]
        if len(cells) >= 3 and cells[2]:
            return cells[2]
    raise SystemExit(f'{readme} 的「最近更新」表缺少唯一非空的 v{version} 说明')


def package_entries(assets_dir: Path, version: str, base_url: str, android_base_url: str) -> dict:
    packages = {}
    for platform, suffix in PLATFORMS.items():
        decoration = r'(?:-adhoc)?' if suffix == '.dmg' else r'(?:-debug-signed)?' if suffix == '.apk' else ''
        pattern = re.compile(rf'BHE-{re.escape(platform)}-v{re.escape(version)}{decoration}{re.escape(suffix)}')
        matches = sorted(p for p in assets_dir.iterdir() if p.is_file() and pattern.fullmatch(p.name))
        if len(matches) > 1:
            raise SystemExit(f'{platform} 有多个安装包：{[p.name for p in matches]}')
        if not matches:
            continue
        path = matches[0]
        if path.stat().st_size <= 0:
            raise ValueError(f'空安装包：{path.name}')
        with path.open('rb') as handle:
            digest = hashlib.file_digest(handle, 'sha256').hexdigest()
        url_base = android_base_url if platform.startswith('android') else base_url
        packages[platform] = {'url': f'{url_base.rstrip("/")}/{path.name}', 'sha256': digest, 'size': path.stat().st_size}
    if not packages:
        raise SystemExit(f'{assets_dir} 里没有 v{version} 的安装包')
    return packages


def build_manifest(tag: str, assets_dir: Path, base_url: str, readme_zh: Path,
                   readme_en: Path, android_base_url: str | None = None) -> dict:
    version = tag.removeprefix('v')
    release_parts(tag)
    notes = {'zh': release_notes(readme_zh, version), 'en': release_notes(readme_en, version)}
    packages = package_entries(assets_dir, version, base_url, android_base_url or base_url)
    _, family, _ = release_parts(tag)
    app_version = version.replace(f'-{family}.', f'+{family}.') if family else version
    for entry in packages.values():
        entry.update(version=app_version, notes=dict(notes))
    return {'version': version, 'published_at': datetime.now(timezone.utc).isoformat(timespec='seconds'),
            'notes': notes, 'packages': packages}


def validate_assets(assets: Path, tag: str, platform: str, entries: dict) -> None:
    base, family, _ = release_parts(tag)
    if platform != (family or 'all'):
        raise ValueError('标签与发布平台不一致')
    expected = set(FAMILIES[family]) if family else set(PLATFORMS)
    if set(entries) != expected:
        raise ValueError(f'安装包架构不完整：需要 {sorted(expected)}')
    matched = {Path(entry['url']).name: entry for entry in entries.values()}
    actual = {p.name for p in assets.iterdir() if p.is_file() and p.name.startswith('BHE-') and p.suffix in PLATFORMS.values()}
    if actual != set(matched):
        raise ValueError('资产中混入错误平台或版本的安装包')
    for name, entry in matched.items():
        checksum = assets / (name + '.sha256')
        if not checksum.is_file() or checksum.read_text().strip().split() != [entry['sha256'], name]:
            raise ValueError(f'{name} 校验文件缺失或不匹配')
    if 'windows-x64' in entries:
        path = assets / Path(entries['windows-x64']['url']).name
        with zipfile.ZipFile(path) as archive:
            # PowerShell 5.1 can store Windows separators in ZIP entry names.
            # Compare normalized paths, but read the exact original ZipInfo.
            manifests = [info for info in archive.infolist()
                         if info.filename.replace('\\', '/').rstrip('/').lower() == 'bhe/bhe-release.json']
            if len(manifests) != 1 or manifests[0].filename.replace('\\', '/') != 'BHE/bhe-release.json':
                raise ValueError('Windows 文件清单缺失或重复')
            inventory = strict_json(archive.read(manifests[0]))
        # Old clients send manifest.version, not the package patch version.
        # Do not publish a ZIP which their unchanged strict helper would reject.
        if inventory.get('schema') != 1 or inventory.get('version') != base:
            raise ValueError('Windows 包不兼容旧客户端的基础版本请求')
        if family == 'windows' and inventory.get('release_version') != tag.removeprefix('v'):
            raise ValueError('Windows 补丁身份与发布标签不一致')
        if inventory.get('release_version', tag.removeprefix('v')) != tag.removeprefix('v'):
            raise ValueError('Windows 文件清单发布版本不匹配')


def merge_manifest(previous: dict, tag: str, assets: Path, base_url: str,
                   readme_zh: Path, readme_en: Path, android_base_url: str | None = None) -> dict:
    validate_manifest(previous)
    base, family, number = release_parts(tag)
    candidate = build_manifest(tag, assets, base_url, readme_zh, readme_en, android_base_url)
    validate_assets(assets, tag, family or 'all', candidate['packages'])
    old_base = version_parts(previous['version'])[0]
    new_base = version_parts(base)[0]
    if family and (new_base < (0, 1, 13) or new_base != old_base):
        raise ValueError('补丁必须基于当前完整版本，且至少为 0.1.13')
    if not family and new_base < old_base:
        raise ValueError('禁止降级完整版本')
    result = copy.deepcopy(previous)
    unchanged = True
    for key, entry in candidate['packages'].items():
        old = previous['packages'][key]
        old_version = old.get('version') or previous['version']
        old_numbers, _, old_number = version_parts(old_version)
        if (new_base, number) < (old_numbers, old_number):
            raise ValueError('禁止覆盖更新的平台版本')
        if (new_base, number) == (old_numbers, old_number):
            old_values = {field: old.get(field) for field in entry}
            # Legacy full releases lack per-package version/notes.
            old_values['version'] = old_version
            old_values['notes'] = old.get('notes') or previous['notes']
            if old_values != entry:
                raise ValueError('同版本内容不同，必须使用新版本')
        else:
            unchanged = False
        result['packages'][key] = {**old, **entry}
    if unchanged:
        return copy.deepcopy(previous)
    if not family:
        result['version'] = base
        result['notes'] = candidate['notes']
    result['published_at'] = candidate['published_at']
    validate_manifest(result)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--tag', required=True)
    parser.add_argument('--assets-dir', type=Path, required=True)
    parser.add_argument('--base-url', required=True)
    parser.add_argument('--android-base-url')
    parser.add_argument('--readme-zh', type=Path, default=ROOT / 'README.md')
    parser.add_argument('--readme-en', type=Path, default=ROOT / 'README.en.md')
    parser.add_argument('--previous-manifest', type=Path)
    parser.add_argument('--previous-signature', type=Path)
    parser.add_argument('--public-key', type=Path, default=PUBLIC_KEY)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.previous_manifest is not None:
            if args.previous_signature is None:
                raise ValueError('旧清单签名缺失')
            previous = read_signed_manifest(args.previous_manifest, args.previous_signature, args.public_key)
            manifest = merge_manifest(previous, args.tag, args.assets_dir, args.base_url,
                                      args.readme_zh, args.readme_en, args.android_base_url)
        else:
            if release_parts(args.tag)[1]:
                raise ValueError('补丁必须提供已签名的旧清单')
            manifest = build_manifest(args.tag, args.assets_dir, args.base_url,
                                      args.readme_zh, args.readme_en, args.android_base_url)
        dump_manifest(manifest, args.out)
    except (ValueError, OSError, zipfile.BadZipFile) as error:
        parser.error(str(error))
    print(f'{args.out}: v{manifest["version"]} {sorted(manifest["packages"])}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
