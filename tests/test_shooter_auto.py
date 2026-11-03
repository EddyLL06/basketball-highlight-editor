import copy
import hashlib
import json
import threading
from pathlib import Path

import cv2
import numpy as np
import pytest

from basketball_engine.protocol import ProtocolError
from basketball_engine.service import EngineService
from basketball_engine.shooter_auto import augment_review, ensure_schema, gallery, observations
from basketball_engine.shooter_auto_pipeline import ProxyReleaseAnalyzer
from basketball_engine.shooter_identity import feature_key
from basketball_engine.storage import ProjectStore
from basketball_engine.release_preview import source_fingerprint


@pytest.fixture
def auto_project(tmp_path, monkeypatch):
    service = EngineService()
    root = tmp_path / 'project'
    service.handle('create_project', {'name': 'Identity test', 'root_path': str(root)})
    store = ProjectStore(root)
    source = tmp_path / 'source.mp4'
    source.write_bytes(b'original-private-footage')
    video = store.link_video({'source_path': str(source), 'source_size_bytes': source.stat().st_size,
        'source_mtime_ns': source.stat().st_mtime_ns, 'width': 960, 'height': 540,
        'duration_ms': 100000, 'fps': 30})
    candidates = [{'id': str(i), 'video_id': video['id'], 'event_time_ms': 10000 * i,
        'default_start_ms': 10000 * i - 3000, 'default_end_ms': 10000 * i + 1000,
        'review_start_ms': 10000 * i - 3000, 'review_end_ms': 10000 * i + 1000,
        'detector_version': 'fixture', 'evidence_json': '{}'} for i in range(1, 7)]
    store.replace_candidates(video['id'], candidates)
    players = [store.create_player(n)['id'] for n in ('A', 'B')]
    ensure_schema(store)
    crop = root / 'artifacts/people.jpg'
    cv2.imwrite(str(crop), np.full((64, 32, 3), 120, np.uint8))
    for c in candidates:
        sample = {'id': 'sample-' + c['id'], 'shot_id': c['id'], 'track_id': 1,
            'time_ms': c['event_time_ms'] - 1000, 'bbox': [0, 0, 32, 64], 'confidence': .9,
            'crop_path': str(crop), 'context_path': str(crop)}
        row = {'candidate_id': c['id'], 'video_id': video['id'], 'event_time_ms': c['event_time_ms'],
            'generation': 'generation-' + c['id'], 'source_fingerprint': source_fingerprint(source),
            'tracks': [{'id': 1, 'samples': [sample]}], 'selected_track_id': 1,
            'context_frames': [], 'display_time_ms': sample['time_ms']}
        with store.connect() as con:
            con.execute('INSERT INTO shooter_auto_observations VALUES (?,?,?,?)',
                (c['id'], row['generation'], json.dumps(row), 'fixture'))
    payload = {'project_root': str(root)}
    for i in range(1, 5):
        service.set_shooter_reference({**payload, 'sample_id': f'sample-{i}',
            'generation': f'generation-{i}', 'player_id': players[int(i > 2)], 'human_confirmed': True})
    try:
        yield service, store, payload, players, source
    finally:
        service.shutdown()


def predictions(store, player, gallery_hash):
    with store.connect() as con:
        for sid in ('5', '6'):
            result = {'status': 'suggested', 'player_id': player, 'confidence_band': 'tentative'}
            con.execute('INSERT INTO shooter_identity_predictions VALUES (?,?,?,?,?,?)',
                (sid, 'generation-' + sid, gallery_hash, 'run', json.dumps(result), 'fixture'))


def test_reference_changes_hide_suggestions_without_changing_labels(auto_project):
    service, store, payload, players, _ = auto_project
    view = service.list_shooter_review(payload)
    assert view['identity_gallery']['ready']
    predictions(store, players[0], view['identity_gallery']['hash'])
    assert service.list_shooter_review(payload)['candidates'][4]['shooter_auto']['prediction']['status'] == 'suggested'
    service.set_shooter_reference({**payload, 'sample_id': 'sample-1', 'remove': True})
    view = service.list_shooter_review(payload)
    assert not view['identity_gallery']['ready']
    assert view['candidates'][4]['shooter_auto']['prediction'] is None
    assert all(c['player_id'] is None for c in store.list_candidates())


def test_manual_names_and_outcomes_survive_batch_adoption_and_reopen(auto_project):
    service, store, payload, players, _ = auto_project
    initial = service.list_shooter_review(payload)
    predictions(store, players[0], initial['identity_gallery']['hash'])
    service.set_candidate_shooter({**payload, 'candidate_id': '5', 'generation': 'generation-5',
        'automatic_evidence': True, 'sample_id': 'sample-5', 'player_id': players[1]})
    with store.connect() as con:
        con.execute("UPDATE candidate_reviews SET status='confirmed',reason='made' WHERE candidate_id='5'")
    before = store.list_candidates()[4]
    result = service.apply_shooter_suggestions({**payload, 'gallery_hash': initial['identity_gallery']['hash']})
    assert result['accepted'] == 1
    reopened = EngineService().list_shooter_review(payload)
    a, b = reopened['candidates'][4:6]
    assert a['player_id'] == players[1] and a['shooter_auto']['selection']['source'] == 'manual'
    assert b['player_id'] == players[0] and b['shooter_auto']['selection']['source'] == 'accepted_suggestion'
    after = store.list_candidates()[4]
    for key in ('review_status', 'review_reason', 'selection_status'):
        assert before.get(key) == after.get(key)


def test_explicit_uncertain_is_not_overridden_and_stale_inputs_are_rejected(auto_project):
    service, store, payload, players, source = auto_project
    view = service.list_shooter_review(payload)
    predictions(store, players[0], view['identity_gallery']['hash'])
    service.set_candidate_shooter({**payload, 'candidate_id': '5', 'generation': 'generation-5',
        'automatic_evidence': True, 'player_id': None, 'review_state': 'uncertain'})
    assert service.apply_shooter_suggestions({**payload, 'gallery_hash': view['identity_gallery']['hash']})['accepted'] == 1
    assert store.list_candidates()[4]['player_id'] is None
    with pytest.raises(ProtocolError):
        service.set_candidate_shooter({**payload, 'candidate_id': '5', 'generation': 'old',
            'automatic_evidence': True, 'player_id': players[0]})
    source.write_bytes(b'changed-source')
    assert not observations(store)
    assert not service.list_shooter_review(payload)['identity_gallery']['references']


def test_references_require_explicit_confirmation_and_current_person(auto_project):
    service, store, payload, players, _ = auto_project
    with pytest.raises(ProtocolError):
        service.set_shooter_reference({**payload, 'sample_id': 'sample-5',
            'generation': 'generation-5', 'player_id': players[0]})
    with pytest.raises(ProtocolError):
        service.set_candidate_shooter({**payload, 'candidate_id': '5', 'generation': 'generation-5',
            'automatic_evidence': True, 'sample_id': 'sample-1', 'player_id': players[0]})
    with pytest.raises(ProtocolError):
        service.apply_shooter_suggestions({**payload, 'gallery_hash': 'stale'})


def test_identity_job_is_opt_in_and_requires_proxy(auto_project):
    service, store, payload, _, _ = auto_project
    assert 'start_shooter_identification' in service._handlers()
    assert not store.list_jobs(store.project()['id'], job_type='shooter_review')
    with pytest.raises(ProtocolError, match='分析代理'):
        service.start_shooter_identification(payload)
    assert not store.list_jobs(store.project()['id'], job_type='shooter_review')


def test_cached_feature_association_never_promotes_names_to_references(auto_project, monkeypatch):
    service, store, payload, players, _ = auto_project
    rows = observations(store)
    before_refs = copy.deepcopy(gallery(store, rows)[0])
    meta = {'sha256': 'f' * 64}
    monkeypatch.setattr(service, '_appearance_model', lambda: (None, meta))
    # Different crops distinguish the two players without a real model in this unit test.
    for i, row in enumerate(rows.values(), 1):
        sample = row['tracks'][0]['samples'][0]
        path = store.root / 'artifacts' / f'person-{i}.jpg'
        cv2.imwrite(str(path), np.full((64, 32, 3), i * 20, np.uint8))
        sample['crop_path'] = str(path)
        with store.connect() as con:
            con.execute('UPDATE shooter_auto_observations SET observation_json=? WHERE candidate_id=?',
                        (json.dumps(row), row['candidate_id']))
        key = feature_key(path.read_bytes(), meta['sha256'])
        cache = store.root / 'artifacts/shooter_auto/features' / f'{key}.json'
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(json.dumps([1, 0] if i in (1, 2, 5, 6) else [0, 1]))
    assert service._associate_shooter_names(store, 'cached-run', ['5', '6'], threading.Event())
    assert gallery(store, observations(store))[0] == before_refs
    view = service.list_shooter_review(payload)
    assert all(r['shooter_auto']['prediction']['player_id'] == players[0] for r in view['candidates'][4:])
    assert all(r['player_id'] is None for r in store.list_candidates())


def test_proxy_pipeline_uses_trimmed_low_resolution_frames_and_reuses_cache(tmp_path):
    source = tmp_path / 'original.mp4'
    source.write_bytes(b'never-open-original')
    proxy = tmp_path / 'proxy.avi'
    writer = cv2.VideoWriter(str(proxy), cv2.VideoWriter_fourcc(*'MJPG'), 5, (160, 120))
    for _ in range(30):
        writer.write(np.full((120, 160, 3), (210, 20, 10), np.uint8))
    writer.release()
    calls = []
    class Ball:
        def predict(self, image, **kwargs):
            assert image.shape[0] == 120 and image.shape[1] <= 160
            assert image[:, :, 0].mean() > image[:, :, 2].mean()
            calls.append(image.shape)
            return [type('Result', (), {'boxes': []})()]
    class People:
        def infer(self, image, region, **kwargs):
            assert region is None  # Missing flight never triggers full-frame people search.
            return {'people': []}
    def analyzer():
        return ProxyReleaseAnalyzer(proxy, source, {'width': 320, 'height': 240},
            {'offset_ms': 2000, 'coarse': {}}, tmp_path / 'cache', People(),
            lambda: (Ball(), 'cpu', [0]), threading.Event(), lambda *a: None)
    a = analyzer()
    candidate = {'id': 'shot', 'video_id': 'video', 'event_time_ms': 5000, 'evidence_json': '{}'}
    result = a.analyze(candidate)
    a.close()
    assert result['input_source'] == 'analysis_proxy' and result['proxy_size'] == [160, 120]
    assert min(f['time_ms'] for f in result['context_frames']) >= 2000
    count = len(calls)
    a = analyzer()
    assert a.analyze(candidate) == result
    a.close()
    assert len(calls) == count
