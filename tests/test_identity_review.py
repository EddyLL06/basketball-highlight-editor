from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
import json
import threading

import pytest

from tools.shooter_identity_review.server import ReviewStore, handler_for


@pytest.fixture
def store(tmp_path):
    rows, samples, features = [], {}, {}
    for key in ('a1', 'a2', 'b1', 'b2', 'query'):
        rows.append({'id': key, 'video_id': key, 'event_time_ms': 10000,
                     'selected_track_id': 1, 'tracks': [{'id': 1, 'sample_ids': [key]}, {'id': 2, 'sample_ids': []}]})
        samples[key] = {'shot_id': key, 'feature_key': key}
        features[key] = [1, 0] if not key.startswith('b') else [0, 1]
    asset = tmp_path/'example.bin'; asset.write_bytes(b'abcdef')
    (tmp_path/'dataset.json').write_text(json.dumps({'rows': rows, 'samples': samples,
        'assets': {'allowed': str(asset)}, 'model': {'sha256': '0'*64}}))
    (tmp_path/'features.json').write_text(json.dumps({'model_sha256': '0'*64, 'features': features}))
    return ReviewStore(tmp_path)


def action(store, **payload):
    return store.mutate({'revision': store.state['revision'], **payload})


def ready(store):
    for key in ('a1', 'a2', 'b1', 'b2'):
        action(store, action='reference', sample_id=key, player_id=key[0], human_confirmed=True)
    return action(store, action='associate')


def test_reference_confirmation_and_persistence_are_separate_from_predictions(store):
    with pytest.raises(ValueError):
        action(store, action='reference', sample_id='a1', player_id='a')
    view = ready(store)
    assert view['run']['results']['query']['player_id'] == 'a'
    assert len(view['references']) == 4 and not view['reviews']
    action(store, action='review', run_id=view['run_id'], items=[
        {'shot_id': 'query', 'status': 'named', 'track_id': 1, 'player_id': 'a'}])
    restarted = ReviewStore(store.root)
    assert restarted.state['reviews']['query']['source'] == 'human_review'
    assert len(restarted.state['references']) == 4
    assert restarted.view()['metrics']['conditional_identity_accuracy']['value'] == 1
    assert restarted.view()['metrics']['counts']['reference_related'] == 4
    action(restarted, action='undo')
    assert not restarted.state['reviews']


def test_wrong_release_person_does_not_become_correct_identity_score(store):
    view = ready(store)
    action(store, action='review', run_id=view['run_id'], items=[
        {'shot_id': 'query', 'status': 'named', 'track_id': 2, 'player_id': 'a'}])
    metrics = store.view()['metrics']
    assert metrics['conditional_identity_accuracy']['denominator'] == 0
    assert metrics['overall_accuracy']['value'] == 0
    assert metrics['assignment_coverage']['value'] == 1


def test_unknown_keeps_coverage_denominator_and_missing_box_is_not_correct(store):
    view = ready(store)
    action(store, action='review', run_id=view['run_id'], items=[
        {'shot_id': 'query', 'status': 'unknown'}])
    assert store.view()['metrics']['correct_coverage']['denominator'] == 1
    assert store.view()['metrics']['overall_accuracy']['value'] is None
    action(store, action='review', run_id=view['run_id'], items=[
        {'shot_id': 'query', 'status': 'named', 'track_id': None, 'player_id': 'a'}])
    assert store.view()['metrics']['overall_accuracy']['value'] == 0


def test_changed_gallery_invalidates_run_and_old_reviews_are_not_reused_as_new_test(store):
    view = ready(store)
    action(store, action='review', run_id=view['run_id'], items=[
        {'shot_id': 'query', 'status': 'named', 'track_id': 1, 'player_id': 'a'}])
    old_run = (store.root/'runs'/f"{view['run_id']}.json").read_bytes()
    action(store, action='reference', sample_id='a1', remove=True)
    assert store.view()['stale']
    with pytest.raises(ValueError):
        action(store, action='review', run_id=view['run_id'], items=[{'shot_id': 'query', 'status': 'unknown'}])
    action(store, action='reference', sample_id='a1', player_id='a', human_confirmed=True)
    new = action(store, action='associate')
    assert new['metrics']['counts']['unreviewed'] == 1
    assert store.state['reviews']['query']['run_id'] == view['run_id']
    assert old_run == (store.root/'runs'/f"{view['run_id']}.json").read_bytes()


def test_stale_revision_and_invalid_batch_leave_saved_records_unchanged(store):
    view = ready(store)
    before = store.path.read_bytes()
    with pytest.raises(ValueError):
        store.mutate({'revision': 0, 'action': 'player', 'name': 'Overwrite'})
    with pytest.raises(ValueError):
        action(store, action='review', run_id=view['run_id'], items=[
            {'shot_id': 'query', 'status': 'named', 'player_id': 'a', 'track_id': 1},
            {'shot_id': 'missing', 'status': 'unknown'}])
    assert store.path.read_bytes() == before
    assert not store.state['reviews']


def test_loopback_http_serves_only_allowlisted_media_and_rejects_foreign_mutations(store):
    server = ThreadingHTTPServer(('127.0.0.1', 0), handler_for(store))
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    connection = HTTPConnection('127.0.0.1', server.server_port)
    try:
        connection.request('GET', '/media/allowed', headers={'Range': 'bytes=1-2'})
        response = connection.getresponse(); assert response.status == 206 and response.read() == b'bc'
        connection.request('GET', '/media/../state.json')
        response = connection.getresponse(); assert response.status == 404; response.read()
        connection.request('POST', '/api/action', body=b'{}', headers={
            'X-BHE-Review': '1', 'Origin': 'https://example.com'})
        response = connection.getresponse(); assert response.status == 403; response.read()
        connection.request('GET', '/api/state')
        response = connection.getresponse(); assert response.status == 200
        assert json.loads(response.read())['revision'] == 0
    finally:
        connection.close(); server.shutdown(); server.server_close(); thread.join(timeout=2)
