#!/usr/bin/env python3
"""One publishing path for full releases and platform patches.

--store-dir is strictly offline. Production transport requires an explicit
--oss-root, credential config, and GitHub Actions (the caller holds the lock).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path, PurePosixPath

from build_update_manifest import (FAMILIES, PLATFORMS, PUBLIC_KEY, dump_manifest, merge_manifest,
                                   read_signed_manifest, release_parts,
                                   verify_signature)


class PublishCancelled(Exception):
    pass


def safe_key(key: str) -> str:
    if not key or key.startswith('/') or '\\' in key or any(p in ('', '.', '..') for p in key.split('/')):
        raise ValueError('对象路径无效')
    return str(PurePosixPath(key))


class DirectoryStore:
    """Filesystem-only OSS substitute; there is no network fallback."""
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.exclusive_download = False

    def path(self, key):
        path = (self.root / safe_key(key)).resolve()
        if not path.is_relative_to(self.root):
            raise ValueError('模拟存储路径越界')
        return path

    def download(self, key: str, target: Path, *, missing_ok=False) -> bool:
        source = self.path(key)
        if not source.is_file():
            if missing_ok:
                return False
            raise ValueError(f'存储对象缺失：{key}')
        with source.open('rb') as input_file, target.open('xb' if self.exclusive_download else 'wb') as output:
            shutil.copyfileobj(input_file, output)
        return True

    def upload(self, source: Path, key: str, *, mutable=False):
        target = self.path(key)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)


class OssStore:
    def __init__(self, args):
        if os.environ.get('GITHUB_ACTIONS') != 'true' or (not args.dry_run and not args.oss_config):
            raise ValueError('生产写入仅允许受共同锁保护的 GitHub Actions，并须显式指定配置')
        if not args.oss_root.startswith('oss://'):
            raise ValueError('OSS 根路径无效')
        self.args = args

    def download(self, key: str, target: Path, *, missing_ok=False) -> bool:
        safe_key(key)
        if key in (self.args.android_key, self.args.android_key + '.sha256'):
            if not self.args.android_alias_url:
                raise ValueError('缺少安卓别名下载地址')
            url = self.args.android_alias_url + ('.sha256' if key.endswith('.sha256') else '')
        else:
            prefix = self.args.prefix + '/'
            if not key.startswith(prefix):
                raise ValueError('对象不属于发布目录')
            name = key[len(prefix):]
            base = self.args.android_base_url if name.endswith(('.apk', '.apk.sha256')) else self.args.base_url
            url = base.rstrip('/') + '/' + name
        request = urllib.request.Request(url, headers={'Cache-Control': 'no-cache'})
        try:
            with urllib.request.urlopen(request, timeout=60) as response, target.open('xb' if self.args.dry_run else 'wb') as output:
                shutil.copyfileobj(response, output)
        except urllib.error.HTTPError as error:
            if missing_ok and error.code == 404:
                return False
            raise ValueError(f'下载发布对象失败：HTTP {error.code}') from error
        return True

    def upload(self, source: Path, key: str, *, mutable=False):
        command = ['ossutil', '--config-file', self.args.oss_config, 'cp', '-f']
        if mutable:
            command += ['--meta', 'Cache-Control:no-cache']
        command += [str(source), self.args.oss_root.rstrip('/') + '/' + safe_key(key)]
        subprocess.run(command, check=True)


def digest(path: Path) -> str:
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


class Summary:
    def __init__(self, path: Path, tag: str, platform: str):
        self.path = path
        self.data = {'tag': tag, 'platform': platform, 'status': 'running', 'stage': 'starting',
                     'run_url': os.environ.get('GITHUB_SERVER_URL', '') + '/' + os.environ.get('GITHUB_REPOSITORY', '') + '/actions/runs/' + os.environ.get('GITHUB_RUN_ID', ''),
                     'events': [], 'previous_verified': False, 'candidate_verified': False}
        self.save()

    def save(self):
        dump_manifest(self.data, self.path)

    def stage(self, name, key=None):
        self.data['stage'] = name
        event = {'stage': name}
        if key is not None:
            event['object'] = key
        self.data['events'].append(event)
        self.save()
        print(f'{name}: {key or ""}', flush=True)


def publish(args, store, summary):
    _, family, _ = release_parts(args.tag)
    if args.platform != (family or 'all'):
        raise ValueError('标签与发布平台不一致；补丁不可使用 all')
    work = args.work_dir
    previous_path = work / 'previous.json'
    previous_signature = work / 'previous.json.sig'
    manifest_key = args.prefix + '/latest.json'
    summary.stage('read-previous', manifest_key)
    store.download(manifest_key, previous_path)
    store.download(manifest_key + '.sig', previous_signature)
    previous = read_signed_manifest(previous_path, previous_signature, args.public_key)
    summary.data['previous_verified'] = True
    summary.save()
    # Already-shipped Windows clients send this exact string to the strict helper.
    if previous['version'] != release_parts(previous['version'])[0]:
        raise ValueError('生产清单顶层版本必须为不带 v 前缀的标准完整版本')
    summary.stage('prepare-candidate')
    candidate = merge_manifest(previous, args.tag, args.assets_dir, args.base_url,
                               args.readme_zh, args.readme_en, args.android_base_url)
    candidate_path = work / 'candidate.json'
    candidate_signature = work / 'candidate.json.sig'
    dump_manifest(candidate, candidate_path)
    subprocess.run(['openssl', 'pkeyutl', '-sign', '-rawin', '-inkey', str(args.signing_key),
                    '-in', str(candidate_path), '-out', str(candidate_signature)], check=True, capture_output=True)
    verify_signature(candidate_path, candidate_signature, args.public_key)
    summary.data['candidate_verified'] = True
    summary.save()
    # Unknown platform extensions remain in the manifest but are never republished.
    targets = list(FAMILIES[family] if family else PLATFORMS)
    files = []
    for platform in targets:
        name = Path(candidate['packages'][platform]['url']).name
        files.extend([args.assets_dir / name, args.assets_dir / (name + '.sha256')])
    summary.stage('preflight-immutable-assets')
    absent = []
    for index, source in enumerate(files):
        key = args.prefix + '/' + source.name
        existing = work / f'existing-{index}'
        if store.download(key, existing, missing_ok=True):
            if digest(existing) != digest(source):
                raise ValueError(f'已发布的同名资产内容不同：{source.name}')
        else:
            absent.append((source, key))
    if args.dry_run:
        objects = [key for _, key in absent]
        for platform in targets:
            source = args.assets_dir / Path(candidate['packages'][platform]['url']).name
            alias = f'BHE-{platform}-latest{source.suffix}'
            key = args.android_key if platform.startswith('android-') else args.prefix + '/' + alias
            objects.extend([key, key + '.sha256'])
        objects.extend([manifest_key + '.sig', manifest_key])
        summary.data.update(status='dry-run-ok', version=candidate['version'],
                            packages={p: candidate['packages'][p] for p in targets},
                            manifest_sha256=digest(candidate_path), unchanged=candidate == previous,
                            would_upload=objects)
        summary.stage('dry-run-complete')
        return
    for source, key in absent:
        summary.stage('upload-versioned', key)
        store.upload(source, key)
    for platform in targets:
        source = args.assets_dir / Path(candidate['packages'][platform]['url']).name
        alias = f'BHE-{platform}-latest{source.suffix}'
        key = args.android_key if platform.startswith('android-') else args.prefix + '/' + alias
        checksum = work / (alias + '.sha256')
        checksum.write_text(f'{digest(source)}  {alias}\n', encoding='utf-8')
        summary.stage('upload-alias', key)
        store.upload(source, key, mutable=True)
        summary.stage('upload-alias-checksum', key + '.sha256')
        store.upload(checksum, key + '.sha256', mutable=True)
    # Two objects are not atomic: interrupted publication must be reported, never hidden.
    summary.stage('upload-manifest-signature', manifest_key + '.sig')
    store.upload(candidate_signature, manifest_key + '.sig', mutable=True)
    summary.stage('upload-manifest', manifest_key)
    store.upload(candidate_path, manifest_key, mutable=True)
    summary.stage('verify-published', manifest_key)
    published = work / 'published.json'
    published_signature = work / 'published.json.sig'
    store.download(manifest_key, published)
    store.download(manifest_key + '.sig', published_signature)
    if read_signed_manifest(published, published_signature, args.public_key) != candidate:
        raise ValueError('发布清单读回不一致')
    summary.data.update(status='success', version=candidate['version'], packages={p: candidate['packages'][p] for p in targets},
                        manifest_sha256=digest(published), unchanged=candidate == previous)
    summary.stage('complete')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    transport = parser.add_mutually_exclusive_group(required=True)
    transport.add_argument('--store-dir', type=Path)
    transport.add_argument('--oss-root')
    parser.add_argument('--oss-config')
    parser.add_argument('--prefix', default='releases')
    parser.add_argument('--android-key', default='android/latest.apk')
    parser.add_argument('--android-alias-url')
    parser.add_argument('--tag', required=True)
    parser.add_argument('--platform', choices=['all', 'macos', 'windows', 'android'], required=True)
    parser.add_argument('--assets-dir', type=Path, required=True)
    parser.add_argument('--base-url', required=True)
    parser.add_argument('--android-base-url')
    parser.add_argument('--readme-zh', type=Path, required=True)
    parser.add_argument('--readme-en', type=Path, required=True)
    parser.add_argument('--public-key', type=Path, default=PUBLIC_KEY)
    parser.add_argument('--signing-key', type=Path, required=True)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--dry-run', action='store_true', help='验证发布并列出将上传的对象，不写入存储')
    args = parser.parse_args(argv)
    args.prefix = safe_key(args.prefix)
    args.android_key = safe_key(args.android_key)
    args.android_base_url = args.android_base_url or args.base_url
    step_summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if args.dry_run and step_summary:
        try:
            if Path(step_summary).stat().st_nlink > 1:
                parser.error('演练摘要目标不能是硬链接')
        except FileNotFoundError:
            pass
    if args.dry_run and args.store_dir is not None:
        store_root = args.store_dir.resolve()
        if args.work_dir.resolve().is_relative_to(store_root):
            parser.error('演练工作目录不能位于模拟存储目录内')
        if step_summary and Path(step_summary).resolve().is_relative_to(store_root):
            parser.error('演练摘要不能位于模拟存储目录内')
        try:
            args.work_dir.mkdir(parents=True, exist_ok=False, mode=0o700)
        except FileExistsError:
            parser.error('离线演练工作目录必须是新建的空目录，请指定新的路径')
    else:
        args.work_dir.mkdir(parents=True, exist_ok=True)
    summary = Summary(args.work_dir / 'publish-summary.json', args.tag, args.platform)
    def cancel(_signal, _frame):
        raise PublishCancelled('发布被取消，检查最后阶段；不得假定官网与更新清单已同时切换')
    previous_handler = signal.signal(signal.SIGTERM, cancel)
    try:
        store = DirectoryStore(args.store_dir) if args.store_dir is not None else OssStore(args)
        if isinstance(store, DirectoryStore):
            store.exclusive_download = args.dry_run
        publish(args, store, summary)
        return 0
    except (Exception, KeyboardInterrupt, SystemExit) as error:
        cancelled = isinstance(error, (KeyboardInterrupt, PublishCancelled))
        summary.data.update(status='cancelled' if cancelled else 'failed', error=str(error))
        summary.save()
        print(f'发布未完成：{summary.data["status"]} at {summary.data["stage"]}: {error}', file=sys.stderr)
        return 130 if cancelled else 1
    finally:
        signal.signal(signal.SIGTERM, previous_handler)
        step_summary = os.environ.get('GITHUB_STEP_SUMMARY')
        if step_summary:
            with open(step_summary, 'a', encoding='utf-8') as output:
                if args.dry_run and os.fstat(output.fileno()).st_nlink > 1:
                    raise ValueError('演练摘要目标不能是硬链接')
                output.write(f'\n### 更新通道发布 {args.tag}\n\n状态：**{summary.data["status"]}**；最后阶段：`{summary.data["stage"]}`。\n\n')
                if args.dry_run:
                    output.write('**未写入 OSS 发布对象；Actions 产物中保存演练文件**。dry-run-ok 不代表正式发布成功。\n\n')
                    output.write('反映的是读取当时的通道状态，不保证之后发布一定成功；如有并行的正式发布请重跑。\n\n')
                    output.write(f'旧清单验签：{summary.data["previous_verified"]}；候选签名验签：{summary.data["candidate_verified"]}。未通过验签的 previous.json 是待验证输入。\n\n')
                    for key in summary.data.get('would_upload', []):
                        output.write(f'- `{key}`\n')
                output.write('同组只保留一个运行项和一个排队项，新的排队项可能取消旧排队项；只有 success 才代表发布完成。\n')


if __name__ == '__main__':
    sys.exit(main())
