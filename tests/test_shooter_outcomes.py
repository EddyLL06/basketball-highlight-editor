import copy

import pytest
from prepare_shooter_outcomes import attach_outcomes


def scene(refined=True):
    rim = {"center_x": 500, "rim_y": 300, "width": 50, "height": 20}
    frames = []
    for step in range(16):
        y = 300 + (-1.5 + step * 0.25) * 50
        frames.append(
            []
            if step in (6, 7)
            else [
                {"name": "ball", "confidence": 0.9, "xyxy": [490, y - 10, 510, y + 10]}
            ]
        )
    predictions = {
        "video": "fixture.mp4",
        "results": [
            {
                "candidate_id": "a",
                "event_time_ms": 1000,
                "tracking_scope": "s",
                "status": "attributed",
                "shooter": {"track_id": 2},
            }
        ],
        "sessions": [{"tracking_scope": "s", "tracks": [{"track_id": 2}]}],
    }
    candidates = {
        "candidates": [
            {
                "id": "a",
                "time": 1,
                "rim": rim,
                "anchor_source": "existing_refined"
                if refined
                else "existing_coarse_fallback",
            }
        ]
    }
    checks = {"video": "fixture.mp4", "results": [{"status": "made", "frames": frames}]}
    return predictions, candidates, checks


def test_actual_engine_make_suggestion_preserves_frozen_shooter_and_inputs():
    inputs = scene()
    original = copy.deepcopy(inputs)
    output = attach_outcomes(*inputs)
    suggestion = output["results"][0].pop("outcome_prediction")
    assert suggestion["shot_outcome"] == "made"
    assert suggestion["rim_check"]["hidden_frames"] == 2
    assert suggestion["human_confirmed"] is False
    assert suggestion["attempt_requires_review"] is True
    assert output == original[0]
    assert inputs == original


@pytest.mark.parametrize("refined,expected", [(True, "unknown"), (False, "missed")])
def test_engine_keep_unless_seen_policy_is_applied_before_prefill(refined, expected):
    predictions, candidates, checks = scene(refined)
    # A raw rejection without observed evidence must remain unknown when the
    # refinement stage did see a crossing. Do not turn every rejection into a miss.
    checks["results"][0] = {"status": "rejected", "frames": [[]] * 16}
    result = attach_outcomes(predictions, candidates, checks)
    suggestion = result["results"][0]["outcome_prediction"]
    assert suggestion["shot_outcome"] == expected
    assert suggestion["rim_check"]["reason"] == "no_crossing"


def test_skipped_rim_check_is_unknown_and_creates_no_human_label():
    predictions, candidates, checks = scene()
    checks["results"][0] = {"status": "skipped", "reason": "no_frames"}
    result = attach_outcomes(predictions, candidates, checks)
    assert result["results"][0]["outcome_prediction"]["shot_outcome"] == "unknown"
    assert "labels" not in result
    assert "is_shot" not in result["results"][0]


def test_millisecond_event_anchor_takes_precedence_over_rounded_display_time():
    predictions, candidates, checks = scene()
    candidates["candidates"][0].update(time=1.00, event_time_ms=1005)
    predictions["results"][0]["event_time_ms"] = 1005
    assert (
        attach_outcomes(predictions, candidates, checks)["results"][0][
            "outcome_prediction"
        ]["shot_outcome"]
        == "made"
    )


@pytest.mark.parametrize("changed", [False, True])
def test_basename_only_archive_requires_original_file_fingerprint(tmp_path, changed):
    predictions, candidates, checks = scene()
    video = tmp_path / "fixture.mp4"
    video.write_bytes(b"video fixture")
    stat = video.stat()
    predictions["video_fingerprint"] = {
        "name": video.name,
        "size": stat.st_size,
        "mtime_ns": stat.st_mtime_ns,
    }
    checks["video"] = candidates["video"] = str(video)
    if changed:
        video.write_bytes(b"different video fixture")
        with pytest.raises(ValueError, match="OUTCOME_VIDEO_MISMATCH"):
            attach_outcomes(predictions, candidates, checks)
    else:
        assert (
            attach_outcomes(predictions, candidates, checks)["results"][0][
                "outcome_prediction"
            ]["shot_outcome"]
            == "made"
        )


@pytest.mark.parametrize("mismatch", ["count", "id", "time", "video", "provenance"])
def test_outcomes_reject_unmatched_candidate_or_video_evidence(mismatch):
    predictions, candidates, checks = scene()
    if mismatch == "count":
        checks["results"] = []
    elif mismatch == "id":
        candidates["candidates"][0]["id"] = "other"
    elif mismatch == "time":
        candidates["candidates"][0]["time"] = 2
    elif mismatch == "video":
        checks["video"] = "other.mp4"
    else:
        del candidates["candidates"][0]["anchor_source"]
    with pytest.raises(ValueError, match="OUTCOME_"):
        attach_outcomes(predictions, candidates, checks)
