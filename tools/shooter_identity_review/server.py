"""Loopback HTML experiment; never opens a BHE project database."""
from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import asdict
from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
import os
from pathlib import Path
import re
import threading
from urllib.parse import urlsplit
from uuid import uuid4

from basketball_engine.shooter_identity import IdentityPolicy, associate_shot, reference_groups


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, indent=2).encode()


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    with temporary.open('wb') as stream:
        stream.write(json_bytes(value))
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def evaluate_run(rows, reviews, run):
    counts = Counter()
    for row in rows:
        prediction = run['results'][row['id']]
        if prediction['status'] == 'reference':
            counts['reference_related'] += 1
            continue
        counts['test_candidates'] += 1
        human = reviews.get(row['id'])
        if not human or human.get('run_id') != run['id']:
            counts['unreviewed'] += 1
            continue
        counts['reviewed'] += 1
        status = human['status']
        counts[status] += 1
        if status not in ('named', 'unknown'):
            counts['non_shot_suggestions'] += int(status == 'not_shot' and prediction['status'] == 'suggested')
            continue
        counts['observable_shots'] += 1
        suggested = prediction['status'] == 'suggested'
        counts['assigned'] += int(suggested)
        if status == 'unknown':
            continue
        counts['assigned_named'] += int(suggested)
        shooter_correct = row['selected_track_id'] is not None and row['selected_track_id'] == human['track_id']
        if shooter_correct:
            counts['correct_shooter_inputs'] += 1
            if suggested:
                counts['identity_assigned'] += 1
                counts['identity_correct'] += int(prediction['player_id'] == human['player_id'])
        if suggested and shooter_correct and prediction['player_id'] == human['player_id']:
            counts['overall_correct'] += 1
    def ratio(n, d):
        return {'numerator': counts[n], 'denominator': counts[d],
                'value': counts[n] / counts[d] if counts[d] else None}
    return {'counts': dict(counts),
            'conditional_identity_accuracy': ratio('identity_correct', 'identity_assigned'),
            'overall_accuracy': ratio('overall_correct', 'assigned_named'),
            'assignment_coverage': ratio('assigned', 'observable_shots'),
            'correct_coverage': ratio('overall_correct', 'observable_shots'),
            'boundary': 'Accuracy uses named human truth. Coverage conservatively includes unknown reviews; explicit unobservable, non-shot, duplicate and reference cases remain separate. Unreviewed cases are not scored.'}


class ReviewStore:
    def __init__(self, root):
        self.root = Path(root).resolve()
        raw = (self.root/'dataset.json').read_bytes()
        self.dataset = json.loads(raw)
        self.fingerprint = hashlib.sha256(raw).hexdigest()
        self.rows = {r['id']: r for r in self.dataset['rows']}
        self.samples = self.dataset['samples']
        feature_bytes = (self.root/'features.json').read_bytes()
        feature_data = json.loads(feature_bytes)
        if feature_data['model_sha256'] != self.dataset['model']['sha256']:
            raise ValueError('人物特征与模型版本不匹配')
        self.feature_hash = hashlib.sha256(feature_bytes).hexdigest()
        self.features = feature_data['features']
        self.lock = threading.RLock()
        self.path = self.root/'state.json'
        if self.path.exists():
            self.state = json.loads(self.path.read_text())
            if self.state['dataset_sha256'] != self.fingerprint:
                raise ValueError('测试数据已变化，请使用独立审核目录')
        else:
            self.state = {'schema': 1, 'dataset_sha256': self.fingerprint, 'revision': 0,
                          'players': [{'id': 'a', 'name': '球员 A'}, {'id': 'b', 'name': '球员 B'}],
                          'references': [], 'gallery_revision': 0, 'reviews': {}, 'undo': [], 'run_id': None}
            atomic_json(self.path, self.state)

    def run(self):
        return json.loads((self.root/'runs'/f"{self.state['run_id']}.json").read_text()) if self.state['run_id'] else None

    def view(self):
        with self.lock:
            run = self.run()
            return {**self.state, 'rows': list(self.rows.values()), 'samples': self.samples,
                    'reference_counts': {pid: len(groups) for pid, groups in reference_groups(
                        self.state['references'], self.samples, self.rows).items()},
                    'model': self.dataset['model'], 'run': run,
                    'stale': bool(run and run['gallery_revision'] != self.state['gallery_revision']),
                    'metrics': evaluate_run(self.rows.values(), self.state['reviews'], run) if run else None}

    def player(self, value):
        if not any(p['id'] == value for p in self.state['players']):
            raise ValueError('球员不存在，请刷新')
        return value

    def mutate(self, payload):
        with self.lock:
            if type(payload.get('revision')) is not int or payload['revision'] != self.state['revision']:
                raise ValueError('页面已更新，请刷新后再保存；旧操作没有覆盖新记录')
            previous = json.loads(json.dumps(self.state))
            try:
                self._apply(payload)
                self.state['revision'] += 1
                self.state['updated_at'] = datetime.now(timezone.utc).isoformat()
                atomic_json(self.root/'history'/f"revision-{self.state['revision']:06d}.json", self.state)
                atomic_json(self.path, self.state)
            except Exception:
                self.state = previous
                raise
            return self.view()

    def _apply(self, p):
        action = p.get('action')
        if action == 'player':
            name = p.get('name')
            if not isinstance(name, str) or not 1 <= len(name.strip()) <= 80:
                raise ValueError('请输入 1–80 字的球员名字')
            name = name.strip()
            pid = p.get('player_id')
            if any(v['name'] == name and v['id'] != pid for v in self.state['players']):
                raise ValueError('该名字已存在')
            if pid:
                self.player(pid)
                next(v for v in self.state['players'] if v['id'] == pid)['name'] = name
            else:
                self.state['players'].append({'id': uuid4().hex, 'name': name})
            return
        if action == 'reference':
            sid = p.get('sample_id')
            if sid not in self.samples or self.samples[sid]['feature_key'] not in self.features:
                raise ValueError('人物图不可用，请换一张')
            if not p.get('remove'):
                player = self.player(p.get('player_id'))
                if p.get('human_confirmed') is not True:
                    raise ValueError('参考人物需要人工明确确认')
            self.state['references'] = [r for r in self.state['references'] if r['sample_id'] != sid]
            if not p.get('remove'):
                self.state['references'].append({'sample_id': sid, 'player_id': player, 'human_confirmed': True})
            self.state['gallery_revision'] += 1
            return
        if action == 'associate':
            policy = IdentityPolicy()
            groups = reference_groups(self.state['references'], self.samples, self.rows, policy)
            if len(self.state['players']) < 2 or any(len(groups.get(v['id'], {})) < policy.min_reference_shots for v in self.state['players']):
                raise ValueError('每位球员至少需要两次不同出手的参考图，建议每人 3–5 张')
            results = {}
            for row in self.rows.values():
                track = next((t for t in row['tracks'] if t['id'] == row['selected_track_id']), None)
                results[row['id']] = associate_shot(row, track['sample_ids'] if track else [],
                    self.state['references'], self.samples, self.rows, self.features, policy)
            run = {'id': uuid4().hex, 'dataset_sha256': self.fingerprint,
                   'gallery_revision': self.state['gallery_revision'],
                   'created_at': datetime.now(timezone.utc).isoformat(), 'policy': asdict(policy),
                   'references': json.loads(json.dumps(self.state['references'])),
                   'model': self.dataset['model'], 'features_sha256': self.feature_hash,
                   'results': results}
            atomic_json(self.root/'runs'/f"{run['id']}.json", run)
            self.state['run_id'] = run['id']
            return
        if action == 'undo':
            if not self.state['undo']:
                raise ValueError('没有可撤销的审核')
            saved = self.state['undo'].pop()
            if saved['previous'] is None:
                self.state['reviews'].pop(saved['shot_id'], None)
            else:
                self.state['reviews'][saved['shot_id']] = saved['previous']
            return
        if action == 'review':
            if p.get('run_id') != self.state['run_id'] or not self.state['run_id']:
                raise ValueError('请先完成关联并刷新')
            run = self.run()
            if run['gallery_revision'] != self.state['gallery_revision']:
                raise ValueError('参考图已变化，请重新关联后审核')
            items = p.get('items')
            if not isinstance(items, list) or not 1 <= len(items) <= len(self.rows):
                raise ValueError('请选择片段')
            if any(not isinstance(item, dict) or not isinstance(item.get('shot_id'), str) for item in items):
                raise ValueError('审核格式无效')
            if len({item['shot_id'] for item in items}) != len(items):
                raise ValueError('同一批不能重复提交同一片段')
            for item in items:
                sid = item.get('shot_id')
                if sid not in self.rows or item.get('status') not in {'named', 'unknown', 'not_shot', 'unobservable', 'duplicate'}:
                    raise ValueError('审核选项无效')
                status = item['status']
                if status == 'named':
                    self.player(item.get('player_id'))
                    track_id = item.get('track_id')
                    if track_id is not None and (type(track_id) is not int or not any(t['id'] == track_id for t in self.rows[sid]['tracks'])):
                        raise ValueError('实际人物框无效，请刷新')
                note = item.get('note', '')
                if not isinstance(note, str) or len(note) > 2000:
                    raise ValueError('备注最多 2000 字')
                self.state['undo'].append({'shot_id': sid, 'previous': self.state['reviews'].get(sid)})
                self.state['reviews'][sid] = {'status': status,
                    'player_id': item.get('player_id') if status == 'named' else None,
                    'track_id': item.get('track_id') if status == 'named' else None,
                    'note': note, 'run_id': run['id'], 'source': 'human_review',
                    'updated_at': datetime.now(timezone.utc).isoformat()}
            return
        raise ValueError('未知操作')


def handler_for(store):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, code, data, kind='application/json; charset=utf-8', extra=None):
            self.send_response(code)
            for key, value in {'Content-Type': kind, 'Content-Length': str(len(data)),
                               'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', **(extra or {})}.items():
                self.send_header(key, value)
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            path = urlsplit(self.path).path
            if path == '/':
                return self.send(200, Path(__file__).with_name('index.html').read_bytes(), 'text/html; charset=utf-8')
            if path == '/review.js':
                return self.send(200, Path(__file__).with_name('review.js').read_bytes(), 'text/javascript; charset=utf-8')
            if path == '/api/state':
                return self.send(200, json_bytes(store.view()))
            if path == '/api/export':
                return self.send(200, json_bytes({'human': store.view(), 'run': store.run()}),
                                 extra={'Content-Disposition': 'attachment; filename="identity-review.json"'})
            asset = store.dataset['assets'].get(path.removeprefix('/media/')) if path.startswith('/media/') else None
            if not asset:
                return self.send(404, b'Not found', 'text/plain')
            file = Path(asset)
            size = file.stat().st_size
            start, end, code = 0, size - 1, 200
            if self.headers.get('Range'):
                match = re.fullmatch(r'bytes=(\d+)-(\d*)', self.headers['Range'])
                if not match:
                    return self.send(416, b'', extra={'Content-Range': f'bytes */{size}'})
                start = int(match[1]); end = min(size-1, int(match[2]) if match[2] else size-1)
                if start > end or start >= size:
                    return self.send(416, b'', extra={'Content-Range': f'bytes */{size}'})
                code = 206
            self.send_response(code)
            for key, value in {'Content-Type': mimetypes.guess_type(str(file))[0] or 'application/octet-stream',
                               'Content-Length': str(end-start+1), 'Accept-Ranges': 'bytes'}.items():
                self.send_header(key, value)
            if code == 206:
                self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.end_headers()
            try:
                with file.open('rb') as stream:
                    stream.seek(start)
                    remaining = end-start+1
                    while remaining:
                        chunk = stream.read(min(1024*256, remaining))
                        if not chunk:
                            break
                        self.wfile.write(chunk); remaining -= len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_POST(self):
            expected = f'http://127.0.0.1:{self.server.server_port}'
            if self.path != '/api/action' or self.headers.get('X-BHE-Review') != '1' or self.headers.get('Origin') not in (None, expected):
                return self.send(403, json_bytes({'error': '仅支持本地审核页面提交'}))
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= 1024*1024:
                    raise ValueError('请求大小无效')
                payload = json.loads(self.rfile.read(length))
                if not isinstance(payload, dict):
                    raise ValueError('请求格式无效')
                self.send(200, json_bytes(store.mutate(payload)))
            except (ValueError, TypeError, KeyError) as exc:
                self.send(400, json_bytes({'error': str(exc)}))
    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--port', type=int, default=0)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler_for(ReviewStore(args.root)))
    atomic_json(args.root/'server.json', {'url': f'http://127.0.0.1:{server.server_port}/'})
    print(f'Review: http://127.0.0.1:{server.server_port}/', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
