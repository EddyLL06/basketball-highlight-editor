import numpy as np
import pytest

from basketball_engine.shooter_identity import (
    IdentityPolicy, associate_shot, feature_key, unit_vector,
)


def fixture_gallery():
    shots = {name: {"id": name, "video_id": name, "event_time_ms": 10000,
                    "selected_track_id": 1} for name in ("a1", "a2", "b1", "b2", "query")}
    samples = {key: {"shot_id": key, "feature_key": key} for key in shots}
    features = {"a1": [1, 0], "a2": [1, .03], "b1": [0, 1], "b2": [.02, 1], "query": [1, .05]}
    refs = [{"sample_id": name, "player_id": name[0], "human_confirmed": True} for name in shots if name != "query"]
    return shots, samples, features, refs


def match(data, query="query"):
    shots, samples, features, refs = data
    return associate_shot(shots[query], [query], refs, samples, shots, features)


def test_matches_named_references_and_keeps_unknown_people_unassigned():
    data = fixture_gallery()
    assert match(data)["player_id"] == "a"
    data[2]["query"] = [-1, -1]
    assert match(data)["status"] == "unknown"
    assert match(data)["reason"] == "below_similarity_threshold"


def test_nearly_identical_players_abstain_even_with_high_similarity():
    data = fixture_gallery()
    data[2].update(b1=[1, .02], b2=[1, .03])
    assert match(data)["reason"] == "similar_players"


def test_reference_shots_and_nearby_duplicate_windows_never_count_as_queries():
    data = fixture_gallery()
    assert match(data, "a1")["status"] == "reference"
    data[0]["query"].update(video_id="a1", event_time_ms=12000)
    assert match(data)["status"] == "reference"
    data[0]["query"].update(video_id="query", group_id="duplicate")
    data[0]["a1"]["group_id"] = "duplicate"
    assert match(data)["status"] == "reference"


def test_machine_predictions_do_not_become_references_and_release_unknown_stays_unknown():
    data = fixture_gallery()
    data[3][0]["human_confirmed"] = False
    assert match(data)["reason"] == "gallery_incomplete"
    data[3][0]["human_confirmed"] = True
    data[0]["query"]["selected_track_id"] = None
    assert match(data)["reason"] == "shooter_unresolved"


def test_multiple_adjacent_reference_frames_do_not_replace_distinct_reference_shots():
    data = fixture_gallery()
    data[3][1]["sample_id"] = "a1"
    assert match(data)["reason"] == "gallery_incomplete"
    data = fixture_gallery()
    data[0]['a2'].update(video_id='a1', event_time_ms=11000)
    assert match(data)["reason"] == "gallery_incomplete"


def test_multi_frame_disagreement_abstains():
    data = fixture_gallery()
    for name, vector in [("q2", [1, .1]), ("q3", [0, 1])]:
        data[1][name] = {"shot_id": "query", "feature_key": name}
        data[2][name] = vector
    result = associate_shot(data[0]["query"], ["query", "q3"], data[3], data[1], data[0], data[2])
    assert result["status"] == "unknown"


def test_features_and_policy_validate_inputs_and_cache_binds_model_and_pixels():
    for vector in ([0, 0], [float("nan"), 1], [[1, 2]]):
        with pytest.raises(ValueError):
            unit_vector(vector)
    assert np.linalg.norm(unit_vector([3, 4])) == pytest.approx(1)
    assert feature_key(b"pixels", "a") != feature_key(b"pixels", "b")
    assert feature_key(b"pixels", "a") != feature_key(b"other", "a")
    with pytest.raises(ValueError):
        IdentityPolicy(min_margin=0)
