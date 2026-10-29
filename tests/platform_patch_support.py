"""Offline release fixtures: temporary keys, tiny packages, no real credentials."""
import hashlib
import json
import subprocess
import zipfile
from pathlib import Path

import build_update_manifest as manifest


class ReleaseFixture:
    def __init__(self, root: Path):
        self.root = root
        root.mkdir(exist_ok=True)
        self.key = root / 'test.key'
        self.public = root / 'test.pub'
        self.zh = root / 'README.md'
        self.en = root / 'README.en.md'
        self.zh.write_text('')
        self.en.write_text('')
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'ED25519', '-out', str(self.key)], check=True, capture_output=True)
        self.key.chmod(0o600)
        subprocess.run(['openssl', 'pkey', '-in', str(self.key), '-pubout', '-out', str(self.public)], check=True, capture_output=True)
        self.notes('v0.1.13')
        assets = self.assets('v0.1.13')
        self.previous = manifest.build_manifest('v0.1.13', assets, 'https://example.invalid/releases', self.zh, self.en)
        self.previous['unknown'] = {'keep': [1, {'nested': True}]}
        self.previous['packages']['macos-arm64']['extension'] = {'a': [1, 2]}

    def notes(self, tag):
        version = tag.removeprefix('v')
        for path, text in [(self.zh, '修复 ' + version), (self.en, 'Fix ' + version)]:
            with path.open('a') as handle:
                handle.write(f'| v{version} | 2026-10-28 | {text} |\n')

    def assets(self, tag):
        version = tag.removeprefix('v')
        base, family, _ = manifest.release_parts(tag)
        folder = self.root / ('assets-' + version)
        folder.mkdir(exist_ok=True)
        keys = manifest.FAMILIES[family] if family else manifest.PLATFORMS
        for platform in keys:
            extension = manifest.PLATFORMS[platform]
            extra = '-adhoc' if extension == '.dmg' else '-debug-signed' if extension == '.apk' else ''
            name = f'BHE-{platform}-v{version}{extra}{extension}'
            path = folder / name
            if extension == '.zip':
                with zipfile.ZipFile(path, 'w') as archive:
                    archive.writestr('BHE/bhe-release.json', json.dumps({'schema': 1, 'version': base, 'release_version': version, 'files': ['BHE.exe'], 'directories': []}))
                    archive.writestr('BHE/BHE.exe', 'synthetic test app')
            else:
                path.write_bytes(name.encode())
            self.checksum(path)
        return folder

    @staticmethod
    def checksum(path):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        path.with_name(path.name + '.sha256').write_text(f'{digest}  {path.name}\n')

    def sign(self, path, key=None):
        signature = path.with_name(path.name + '.sig')
        subprocess.run(['openssl', 'pkeyutl', '-sign', '-rawin', '-inkey', str(key or self.key), '-in', str(path), '-out', str(signature)], check=True, capture_output=True)
        return signature

    def signed_previous(self, value=None):
        path = self.root / 'latest.json'
        manifest.dump_manifest(self.previous if value is None else value, path)
        return path, self.sign(path)

    def merge(self, tag, previous=None, assets=None):
        self.notes(tag)
        assets = assets or self.assets(tag)
        return manifest.merge_manifest(self.previous if previous is None else previous, tag, assets,
                                       'https://example.invalid/releases', self.zh, self.en,
                                       'https://android.example.invalid/releases')
