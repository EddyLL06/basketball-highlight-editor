"""Project-local identity references and independently requested shooter jobs."""
from __future__ import annotations

from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import threading
from uuid import uuid4

from .adapters.analysis import PipelineCancelled
from .protocol import ProtocolError
from .release_preview import cached_context, source_fingerprint
from .shooter_auto_pipeline import ProxyReleaseAnalyzer, atomic_json, digest
from .shooter_identity import IdentityPolicy, TorchScriptAppearance, associate_shot, feature_key, reference_groups
from .storage import now_iso

AUTO_SCHEMA = """
CREATE TABLE IF NOT EXISTS shooter_auto_observations (
    candidate_id TEXT PRIMARY KEY REFERENCES candidates(id) ON DELETE CASCADE,
    generation TEXT NOT NULL, observation_json TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS shooter_identity_references (
    sample_id TEXT PRIMARY KEY,
    candidate_id TEXT NOT NULL REFERENCES candidates(id) ON DELETE CASCADE,
    player_id TEXT NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    generation TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS shooter_identity_predictions (
    candidate_id TEXT PRIMARY KEY REFERENCES candidates(id) ON DELETE CASCADE,
    generation TEXT NOT NULL, gallery_hash TEXT NOT NULL, run_id TEXT NOT NULL,
    prediction_json TEXT NOT NULL, updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS shooter_identity_selections (
    candidate_id TEXT PRIMARY KEY REFERENCES candidates(id) ON DELETE CASCADE,
    generation TEXT NOT NULL, selection_json TEXT NOT NULL, updated_at TEXT NOT NULL
);
"""


def ensure_schema(store):
    with store.connect() as connection:
        connection.executescript(AUTO_SCHEMA)


def model_metadata():
    root = Path(os.environ.get('BHE_RUNTIME_ROOT') or Path(__file__).resolve().parents[3])
    manifest = root / 'models/shooter-appearance.json'
    try:
        meta = json.loads(manifest.read_text())
        path = root / 'models' / meta['file']
        if path.parent.resolve() != (root / 'models').resolve() or not path.is_file():
            raise ValueError('Invalid model location')
        if len(meta['sha256']) != 64:
            raise ValueError('Invalid model checksum')
        return path, meta
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise ProtocolError('SHOOTER_MODEL_MISSING', '自动识别模型不可用，请安装完整版本；仍可人工标注') from exc


def observations(store):
    with store.connect() as connection:
        saved = [json.loads(r[0]) for r in connection.execute('SELECT observation_json FROM shooter_auto_observations')]
    videos = {v['id']: v for v in store.list_videos()}
    current = {c['id']: c for c in store.list_candidates()}
    fingerprints = {}
    result = {}
    for row in saved:
        video = videos.get(row['video_id'])
        candidate = current.get(row['candidate_id'])
        if not video or not candidate or candidate['event_time_ms'] != row['event_time_ms']:
            continue
        try:
            if video['id'] not in fingerprints:
                fingerprints[video['id']] = source_fingerprint(Path(video['source_path']))
            if fingerprints[video['id']] == row['source_fingerprint']:
                result[row['candidate_id']] = row
        except OSError:
            continue
    return result


def inputs(rows):
    shots, samples = {}, {}
    for row in rows.values():
        shots[row['candidate_id']] = {'id': row['candidate_id'], 'video_id': row['video_id'],
            'event_time_ms': row['event_time_ms'], 'selected_track_id': row['selected_track_id']}
        for track in row['tracks']:
            for sample in track['samples']:
                samples[sample['id']] = sample
    return shots, samples


def gallery(store, rows, connection=None):
    shots, samples = inputs(rows)
    if connection is None:
        with store.connect() as con:
            saved = [dict(r) for r in con.execute('SELECT * FROM shooter_identity_references ORDER BY sample_id')]
    else:
        saved = [dict(r) for r in connection.execute('SELECT * FROM shooter_identity_references ORDER BY sample_id')]
    refs = [{**ref, 'human_confirmed': True} for ref in saved if ref['sample_id'] in samples
            and rows[ref['candidate_id']]['generation'] == ref['generation']
            and Path(samples[ref['sample_id']]['crop_path']).is_file()]
    groups = reference_groups(refs, samples, shots)
    counts = {pid: len(events) for pid, events in groups.items()}
    ready = len(counts) >= 2 and all(n >= IdentityPolicy().min_reference_shots for n in counts.values())
    return refs, counts, ready, digest([{k:r[k] for k in ('sample_id', 'player_id', 'generation')} for r in refs])


def augment_review(store, view):
    ensure_schema(store)
    rows = observations(store)
    refs, counts, ready, gallery_hash = gallery(store, rows)
    _, samples = inputs(rows)
    with store.connect() as connection:
        predictions = {r['candidate_id']: dict(r) for r in connection.execute('SELECT * FROM shooter_identity_predictions')}
        selections = {r['candidate_id']: json.loads(r['selection_json'])
                      for r in connection.execute('SELECT * FROM shooter_identity_selections')}
    for candidate in view['candidates']:
        observation = rows.get(candidate['id'])
        if not observation or candidate.get('draft'):
            continue
        prediction = predictions.get(candidate['id'])
        valid = prediction and prediction['gallery_hash'] == gallery_hash and prediction['generation'] == observation['generation']
        selected = selections.get(candidate['id'])
        if selected and selected.get('player_id') == candidate.get('player_id'):
            candidate['shooter_review_state'] = selected['review_state']
        elif candidate.get('player_id'):
            candidate['shooter_review_state'] = 'confirmed'
        candidate['shooter_auto'] = {**observation,
            'prediction': {**json.loads(prediction['prediction_json']), 'run_id': prediction['run_id']} if valid else None,
            'selection': selected if selected and selected['generation'] == observation['generation']
                and selected.get('player_id') == candidate.get('player_id') else None}
    view['identity_gallery'] = {'ready': ready, 'counts': counts, 'hash': gallery_hash,
        'references': [{**ref, 'crop_path': samples[ref['sample_id']]['crop_path']} for ref in refs]}
    return view


class ShooterAutoMixin:
    def _appearance_model(self):
        path, meta = model_metadata()
        key = (str(path), meta['sha256'])
        cached = getattr(self, '_appearance_cache', None)
        if cached is None or cached[0] != key:
            cached = (key, TorchScriptAppearance(path, meta['sha256']))
            self._appearance_cache = cached
        return cached[1], meta

    @staticmethod
    def _shooter_ball_path():
        root = Path(os.environ.get('BHE_RUNTIME_ROOT') or Path(__file__).resolve().parents[3])
        path = root / 'models/bball_model.pt'
        if not path.is_file():
            path = root / 'third_party/basketball-shot-detection/bball_model.pt'
        return path

    def _shooter_ball_model(self):
        from basketball_highlight.inference import load_detector, select_device, current_device
        path = self._shooter_ball_path()
        model = load_detector(path, device=select_device('auto', path), imgsz=640)
        names = model.names
        classes = [int(i) for i, name in (names.items() if isinstance(names, dict) else enumerate(names))
                   if str(name).lower() == 'ball']
        if not classes:
            raise ProtocolError('SHOOTER_MODEL_INVALID', '篮球模型不支持当前识别任务')
        return model, current_device(), classes

    def start_shooter_identification(self, payload):
        with self._job_lock:
            self._job_threads = {k:t for k,t in self._job_threads.items() if t.is_alive()}
            store = self._require_store(payload)
            ensure_schema(store)
            if self._job_threads or self._unfinished_heavy_jobs(store, store.project()['id']):
                raise ProtocolError('JOB_ALREADY_RUNNING', '请先完成或取消现有分析、导出或识别任务')
            candidates = [c for c in store.list_candidates() if not payload.get('video_id') or c['video_id'] == payload['video_id']]
            if not candidates:
                raise ProtocolError('SHOOTER_NO_CANDIDATES', '请先分析并生成候选片段')
            videos = [v for v in store.list_videos() if any(c['video_id'] == v['id'] for c in candidates)]
            for video in videos:
                source = self._validated_source(video)
                if cached_context(store, video, source)['proxy'].resolve() == source.resolve():
                    raise ProtocolError('PERSON_PROXY_REQUIRED', '请先完成视频分析，自动识别只使用分析代理')
            # Check packaged resources before creating a job; manual labeling remains usable.
            model_metadata()
            from .person_candidates import person_model_path
            person_model_path()
            job = store.create_job(store.project()['id'], videos[0]['id'] if len(videos) == 1 else None,
                'shooter_review', {'automatic_shooter': True, 'video_ids': [v['id'] for v in videos]})
            job_id = job['id']
            self._job_cancel_events[job_id] = threading.Event()
            thread = threading.Thread(target=self._run_shooter_identification,
                args=(dict(payload), job_id, videos, candidates), daemon=True, name=f'identity-{job_id}')
            self._job_threads[job_id] = thread
            try:
                thread.start()
            except RuntimeError:
                self._job_threads.pop(job_id, None)
                self._job_cancel_events.pop(job_id, None)
                store.update_job(job_id, state='failed', error_code='SHOOTER_PREPARE_FAILED', error_message='无法启动识别任务')
                raise
            return {'job': job}

    def _run_shooter_identification(self, payload, job_id, videos, candidates):
        store = self._require_store(payload)
        cancel = self._job_cancel_events[job_id]
        generated = []
        try:
            detector = self._region_person_candidates()
            for index, video in enumerate(videos):
                source = self._validated_source(video)
                context = cached_context(store, video, source)
                subset = [c for c in candidates if c['video_id'] == video['id']]
                ordinal = 0
                def progress(value, stage='shooter_people'):
                    if cancel.is_set():
                        raise PipelineCancelled('JOB_CANCELLED')
                    fraction = (ordinal + value) / len(subset)
                    store.update_job(job_id, state='running', stage=stage, progress=.85 * (index + fraction) / len(videos))
                analyzer = ProxyReleaseAnalyzer(context['proxy'], source, video, context,
                    store.root / 'artifacts/shooter_auto' / video['id'], detector,
                    self._shooter_ball_model, cancel, progress,
                    ball_fingerprint=hashlib.sha256(self._shooter_ball_path().read_bytes()).hexdigest())
                try:
                    for ordinal, candidate in enumerate(subset):
                        generated.append(analyzer.analyze(candidate))
                        progress(1)
                finally:
                    analyzer.close()
            if cancel.is_set():
                raise PipelineCancelled('JOB_CANCELLED')
            current = {c['id']: c for c in store.list_candidates()}
            for row in generated:
                if (row['candidate_id'] not in current or current[row['candidate_id']]['event_time_ms'] != row['event_time_ms']
                        or source_fingerprint(self._validated_source(store.video(row['video_id']))) != row['source_fingerprint']):
                    raise ProtocolError('SHOOTER_CANDIDATES_CHANGED', '候选或视频已变化，请重新识别')
            with store.connect() as connection:
                for row in generated:
                    connection.execute('INSERT INTO shooter_auto_observations VALUES (?,?,?,?) ON CONFLICT(candidate_id) '
                        'DO UPDATE SET generation=excluded.generation, observation_json=excluded.observation_json, updated_at=excluded.updated_at',
                        (row['candidate_id'], row['generation'], json.dumps(row, ensure_ascii=False), now_iso()))
            ready = self._associate_shooter_names(store, job_id, [c['id'] for c in candidates], cancel)
            store.update_job(job_id, state='completed', stage='completed' if ready else 'shooter_references', progress=1)
        except PipelineCancelled:
            store.update_job(job_id, state='cancelled', stage='cancelled', error_code='JOB_CANCELLED',
                             error_message='已取消，保留原人工标注与已完成的缓存')
        except Exception as exc:
            store.update_job(job_id, state='failed', stage='shooter_identification',
                error_code=exc.code if isinstance(exc, ProtocolError) else 'SHOOTER_PREPARE_FAILED', error_message=str(exc))
        finally:
            with self._job_lock:
                self._job_threads.pop(job_id, None)
                self._job_cancel_events.pop(job_id, None)

    def _associate_shooter_names(self, store, run_id, candidate_ids, cancel):
        import cv2
        rows = observations(store)
        refs, _, ready, gallery_hash = gallery(store, rows)
        if not ready:
            return False
        encoder, meta = self._appearance_model()
        shots, samples = inputs(rows)
        features = {}
        entries = []
        for sample in samples.values():
            path = Path(sample['crop_path'])
            if not path.is_file():
                continue
            key = feature_key(path.read_bytes(), meta['sha256'])
            sample['feature_key'] = key
            cache = store.root / 'artifacts/shooter_auto/features' / f'{key}.json'
            try:
                features[key] = json.loads(cache.read_text())
            except (OSError, ValueError):
                entries.append((key, path, cache))
        for index in range(0, len(entries), 24):
            if cancel.is_set():
                raise PipelineCancelled('JOB_CANCELLED')
            batch = entries[index:index + 24]
            for (key, _, cache), vector in zip(batch, encoder.encode([cv2.imread(str(p)) for _,p,_ in batch])):
                features[key] = vector
                atomic_json(cache, vector)
            store.update_job(run_id, state='running', stage='shooter_names', progress=.9 + .09 * (index + len(batch)) / len(entries))
        results = {}
        for sid in candidate_ids:
            if sid not in rows:
                continue
            track = next((t for t in rows[sid]['tracks'] if t['id'] == rows[sid]['selected_track_id']), None)
            results[sid] = associate_shot(shots[sid], [s['id'] for s in track['samples']] if track else [],
                                         refs, samples, shots, features)
        if cancel.is_set():
            raise PipelineCancelled('JOB_CANCELLED')
        if gallery(store, observations(store))[3] != gallery_hash:
            raise ProtocolError('SHOOTER_REFERENCES_CHANGED', '参考图已更新，请再次识别；原人工标签保留')
        atomic_json(store.root / 'artifacts/shooter_auto/runs' / f'{run_id}.json', {
            'id': run_id, 'gallery_hash': gallery_hash, 'references': refs, 'policy': asdict(IdentityPolicy()),
            'model': meta, 'results': results, 'created_at': now_iso()})
        with store.connect() as connection:
            for sid, result in results.items():
                connection.execute('INSERT INTO shooter_identity_predictions VALUES (?,?,?,?,?,?) ON CONFLICT(candidate_id) '
                    'DO UPDATE SET generation=excluded.generation, gallery_hash=excluded.gallery_hash, run_id=excluded.run_id, '
                    'prediction_json=excluded.prediction_json, updated_at=excluded.updated_at',
                    (sid, rows[sid]['generation'], gallery_hash, run_id, json.dumps(result), now_iso()))
        return True

    def set_shooter_reference(self, payload):
        store = self._require_store(payload)
        ensure_schema(store)
        rows = observations(store)
        _, samples = inputs(rows)
        sid = payload.get('sample_id')
        if payload.get('remove'):
            with store.connect() as connection:
                connection.execute('DELETE FROM shooter_identity_references WHERE sample_id=?', (sid,))
        else:
            sample = samples.get(sid)
            if not sample or payload.get('generation') != rows[sample['shot_id']]['generation']:
                raise ProtocolError('SHOOTER_EVIDENCE_CHANGED', '人物画面已更新，请刷新后重选参考图')
            if payload.get('human_confirmed') is not True:
                raise ProtocolError('INVALID_REQUEST', '请明确确认参考图中的球员')
            pid = payload.get('player_id')
            if not any(p['id'] == pid for p in store.list_players()):
                raise ProtocolError('INVALID_REQUEST', '请选择当前项目的球员')
            with store.connect() as connection:
                connection.execute('INSERT INTO shooter_identity_references VALUES (?,?,?,?,?) ON CONFLICT(sample_id) '
                    'DO UPDATE SET player_id=excluded.player_id, generation=excluded.generation, updated_at=excluded.updated_at',
                    (sid, sample['shot_id'], pid, payload['generation'], now_iso()))
        return {'updated': True}

    def set_auto_shooter(self, payload):
        store = self._require_store(payload)
        ensure_schema(store)
        rows = observations(store)
        sid = payload.get('candidate_id')
        row = rows.get(sid)
        if not row or row['generation'] != payload.get('generation'):
            raise ProtocolError('SHOOTER_EVIDENCE_CHANGED', '人物画面已更新，请刷新后重试')
        status, pid = payload.get('review_state', 'confirmed'), payload.get('player_id')
        if status not in ('confirmed', 'pending', 'uncertain') or (status == 'confirmed') != bool(pid):
            raise ProtocolError('INVALID_REQUEST', '请选择球员或标为不确定')
        if pid and not any(p['id'] == pid for p in store.list_players()):
            raise ProtocolError('INVALID_REQUEST', '球员不属于当前项目')
        _, samples = inputs({sid: row})
        sample = samples.get(payload.get('sample_id'))
        if payload.get('sample_id') is not None and not sample:
            raise ProtocolError('INVALID_REQUEST', '人物与当前出手不匹配')
        selection = {'generation': row['generation'], 'player_id': pid, 'review_state': status,
            'sample_id': sample['id'] if sample else None, 'track_id': sample['track_id'] if sample else None,
            'time_ms': sample['time_ms'] if sample else None, 'source': 'manual'}
        with store.connect() as connection:
            self._write_auto_selection(connection, sid, selection)
        return {'selection': selection, 'review_state': status}

    @staticmethod
    def _write_auto_selection(connection, sid, selection):
        connection.execute("INSERT INTO candidate_reviews(candidate_id,player_id,status,updated_at) VALUES(?,?,'pending',?) "
            'ON CONFLICT(candidate_id) DO UPDATE SET player_id=excluded.player_id,updated_at=excluded.updated_at',
            (sid, selection['player_id'], now_iso()))
        connection.execute('INSERT INTO shooter_identity_selections VALUES (?,?,?,?) ON CONFLICT(candidate_id) '
            'DO UPDATE SET generation=excluded.generation,selection_json=excluded.selection_json,updated_at=excluded.updated_at',
            (sid, selection['generation'], json.dumps(selection), now_iso()))

    def apply_shooter_suggestions(self, payload):
        store = self._require_store(payload)
        view = self.list_shooter_review(payload)
        if payload.get('gallery_hash') != view['identity_gallery']['hash']:
            raise ProtocolError('SHOOTER_REFERENCES_CHANGED', '参考图已更新，请重新识别')
        requested = payload.get('candidate_ids')
        if requested is not None and (not isinstance(requested, list) or
                any(not isinstance(sid, str) for sid in requested) or len(set(requested)) != len(requested) or
                not set(requested).issubset({c['id'] for c in view['candidates']})):
            raise ProtocolError('INVALID_REQUEST', '候选选择已变化，请刷新后重试')
        accepted = 0
        current_rows = observations(store)
        with store.connect() as connection:
            connection.execute('BEGIN IMMEDIATE')
            if gallery(store, current_rows, connection)[3] != payload.get('gallery_hash'):
                raise ProtocolError('SHOOTER_REFERENCES_CHANGED', '参考图已更新，请重新识别')
            for candidate in view['candidates']:
                if requested is not None and candidate['id'] not in requested:
                    continue
                if payload.get('video_id') and candidate['video_id'] != payload['video_id']:
                    continue
                auto = candidate.get('shooter_auto') or {}
                prediction = auto.get('prediction') or {}
                if candidate.get('player_id') or candidate['shooter_review_state'] != 'pending' or prediction.get('status') != 'suggested':
                    continue
                current = connection.execute('SELECT player_id FROM candidate_reviews WHERE candidate_id=?',
                                             (candidate['id'],)).fetchone()
                selection = connection.execute('SELECT selection_json FROM shooter_identity_selections WHERE candidate_id=?',
                                               (candidate['id'],)).fetchone()
                prior = connection.execute('SELECT review_state FROM shooter_review_evidence WHERE candidate_id=?',
                                           (candidate['id'],)).fetchone()
                if (current and current['player_id']) or (selection and
                        json.loads(selection['selection_json'])['review_state'] != 'pending') or (
                        prior and prior['review_state'] in ('confirmed', 'uncertain')):
                    continue
                live = connection.execute('SELECT generation,run_id,gallery_hash FROM shooter_identity_predictions WHERE candidate_id=?',
                                          (candidate['id'],)).fetchone()
                observation = connection.execute('SELECT generation FROM shooter_auto_observations WHERE candidate_id=?',
                                                 (candidate['id'],)).fetchone()
                if (candidate['id'] not in current_rows or current_rows[candidate['id']]['generation'] != auto['generation']
                        or not observation or observation['generation'] != auto['generation']
                        or not live or live['run_id'] != prediction['run_id'] or live['gallery_hash'] != payload['gallery_hash']):
                    raise ProtocolError('SHOOTER_EVIDENCE_CHANGED', '识别结果已更新，请刷新后重试')
                track = next((t for t in auto['tracks'] if t['id'] == auto['selected_track_id']), None)
                if not track or not track['samples']:
                    continue
                sample = track['samples'][0]
                # Source stays distinct from individually inspected human labels.
                self._write_auto_selection(connection, candidate['id'], {'generation': auto['generation'],
                    'player_id': prediction['player_id'], 'review_state': 'confirmed',
                    'sample_id': sample['id'], 'track_id': sample['track_id'], 'time_ms': sample['time_ms'],
                    'source': 'accepted_suggestion', 'run_id': prediction['run_id']})
                accepted += 1
        return {'accepted': accepted}
