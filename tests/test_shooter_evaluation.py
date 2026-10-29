import json
import threading
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest
from review_shooters import make_server, validate_label

from basketball_highlight.shooter_evaluation import evaluate_shooters


def predictions():
    return {
        "results": [
            {
                "candidate_id": "a",
                "tracking_scope": "s",
                "status": "attributed",
                "shooter": {"track_id": 1, "score": 0.9},
                "processing_seconds": 1,
            },
            {
                "candidate_id": "b",
                "tracking_scope": "s",
                "status": "attributed",
                "shooter": {"track_id": 2, "score": 0.8},
                "processing_seconds": 2,
            },
            {
                "candidate_id": "c",
                "tracking_scope": "s",
                "status": "unknown",
                "shooter": None,
                "processing_seconds": 3,
            },
        ],
        "sessions": [
            {"tracking_scope": "s", "tracks": [{"track_id": 1}, {"track_id": 2}]}
        ],
    }


def labels():
    return [
        {
            "candidate_id": c,
            "tracking_scope": "s",
            "is_scoring": True,
            "shooter_track_id": 1,
        }
        for c in "abc"
    ]


def test_evaluation_precision_coverage_and_unknown_rate():
    report = evaluate_shooters(predictions(), labels())
    assert report["precision"] == 0.5
    assert report["coverage"] == 2 / 3
    assert report["unknown_rate"] == 1 / 3
    assert report["mean_seconds_per_candidate"] == 2


def test_unreviewed_unknown_and_stale_labels_do_not_inflate_accuracy():
    assert evaluate_shooters(predictions(), [])["precision"] is None
    data = labels()
    data[0]["tracking_scope"] = "old-session"
    data[1]["shooter_track_id"] = None
    report = evaluate_shooters(predictions(), data)
    assert report["stale_or_unmatched_labels"] == ["a"]
    assert report["precision"] is None
    assert report["predictions_without_resolvable_truth"] == 1


def test_non_scoring_event_excluded_from_shooter_metrics():
    data = labels()
    data[1]["is_scoring"] = False
    report = evaluate_shooters(predictions(), data)
    assert report["precision"] == 1
    assert report["coverage"] == 0.5
    assert report["non_scoring_candidates"] == 1
    assert report["attributions_on_non_scoring_candidates"] == 1
    assert report["assigned_reviewed_candidates"] == 2


def test_duplicate_labels_rejected():
    with pytest.raises(ValueError, match="DUPLICATE"):
        evaluate_shooters(predictions(), [labels()[0]] * 2)


def test_review_labels_must_belong_to_the_temporary_tracking_scope():
    assert validate_label(labels()[0], predictions())["shooter_track_id"] == 1
    wrong = {**labels()[0], "shooter_track_id": 100}
    with pytest.raises(ValueError, match="Select a track"):
        validate_label(wrong, predictions())
    with pytest.raises(ValueError, match="session changed"):
        validate_label({**labels()[0], "tracking_scope": "elsewhere"}, predictions())


def test_temporary_review_server_video_ranges_and_persisted_feedback(tmp_path):
    video = tmp_path / "video.mp4"
    video.write_bytes(b"0123456789")
    label_file = tmp_path / "labels.json"
    server = make_server(predictions(), video, label_file, 0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    origin = f"http://127.0.0.1:{server.server_port}"
    try:
        with urlopen(
            Request(origin + "/video", headers={"Range": "bytes=2-5"})
        ) as response:
            assert response.status == 206
            assert response.read() == b"2345"
        body = json.dumps(labels()[0]).encode()
        with urlopen(
            Request(
                origin + "/labels",
                data=body,
                headers={"Origin": origin, "Content-Type": "application/json"},
            )
        ) as response:
            assert json.load(response)["saved"]
        assert json.loads(label_file.read_text())[0]["candidate_id"] == "a"
        missed = {
            **labels()[0],
            "is_scoring": False,
            "is_shot": True,
            "shot_outcome": "missed",
        }
        with urlopen(
            Request(
                origin + "/labels",
                data=json.dumps(missed).encode(),
                headers={"Origin": origin, "Content-Type": "application/json"},
            )
        ) as response:
            assert json.load(response)["label"]["shooter_track_id"] == 1
        stored = json.loads(label_file.read_text())[0]
        assert stored["shot_outcome"] == "missed"
        assert stored["is_shot"] is True
        assert stored["shooter_track_id"] == 1
        with pytest.raises(HTTPError) as exc:
            urlopen(
                Request(
                    origin + "/labels",
                    data=body,
                    headers={
                        "Origin": "http://unrelated.invalid",
                        "Content-Type": "application/json",
                    },
                )
            )
        assert exc.value.code == 403
        with pytest.raises(HTTPError):
            urlopen(origin + "/../private")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
