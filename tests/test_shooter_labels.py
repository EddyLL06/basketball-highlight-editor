import pytest
from review_shooters import validate_label

from basketball_highlight.shooter_evaluation import evaluate_attempts, evaluate_shooters
from basketball_highlight.shooter_labels import (
    normalize_shot_label,
    summarize_linked_field_goals,
)


def scene():
    return {
        "results": [
            {
                "candidate_id": str(i),
                "tracking_scope": "s",
                "status": "attributed" if i < 2 else "unknown",
                "shooter": {"track_id": i + 1, "score": 0.9} if i < 2 else None,
            }
            for i in range(3)
        ],
        "sessions": [
            {"tracking_scope": "s", "tracks": [{"track_id": 1}, {"track_id": 2}]}
        ],
    }


def label(candidate, outcome, shooter):
    return {
        "candidate_id": str(candidate),
        "tracking_scope": "s",
        "is_shot": True,
        "shot_outcome": outcome,
        "shooter_track_id": shooter,
    }


def test_missed_shot_preserves_shooter_and_persisted_legacy_compatibility():
    saved = validate_label(label(1, "missed", 2), scene())
    assert saved["is_scoring"] is False
    assert saved["is_shot"] is True
    assert saved["shot_outcome"] == "missed"
    assert saved["shooter_track_id"] == 2
    assert saved["review_kind"] == "scoped_shooter"
    assert normalize_shot_label(saved) == saved


def test_attempt_metrics_include_misses_and_do_not_count_unknown_as_correct():
    labels = [label(0, "made", 1), label(1, "missed", 2), label(2, "missed", 1)]
    result = evaluate_attempts(scene(), labels)
    assert result["reviewed_attempt_candidates"] == 3
    assert result["coverage"] == 2 / 3
    assert result["correct_predictions"] == 2
    assert result["precision_denominator"] == 2
    assert result["by_outcome"]["missed"]["coverage"] == 0.5
    assert result["by_outcome"]["missed"]["correct_predictions"] == 1
    assert evaluate_shooters(scene(), labels)["reviewed_scoring_events"] == 1


def test_legacy_not_made_is_unclassified_not_automatically_missed_or_non_shot():
    raw = {
        "candidate_id": "0",
        "tracking_scope": "s",
        "is_scoring": False,
        "shooter_track_id": None,
        "note": "track 1 correct",
    }
    result = evaluate_attempts(scene(), [raw])
    assert result["reviewed_attempt_candidates"] == 0
    assert result["explicit_non_shot_candidates"] == 0
    assert result["unclassified_legacy_not_made_candidates"] == 1
    assert "is_shot" not in raw


def test_non_shot_attribution_is_distinct_from_correct_shooter_on_miss():
    labels = [
        label(1, "missed", 2),
        {
            "candidate_id": "0",
            "tracking_scope": "s",
            "is_shot": False,
            "shot_outcome": None,
            "shooter_track_id": None,
        },
    ]
    result = evaluate_attempts(scene(), labels)
    assert result["correct_predictions"] == 1
    assert result["explicit_non_shot_candidates"] == 1
    assert result["attributions_on_explicit_non_shots"] == 1


def test_shooter_can_be_resolved_with_unknown_shot_outcome():
    saved = validate_label(label(0, "unknown", 1), scene())
    assert saved["is_scoring"] is None
    assert evaluate_attempts(scene(), [saved])["correct_predictions"] == 1
    report = evaluate_shooters(scene(), [saved])
    assert report["reviewed_scoring_events"] == 0
    assert report["attempt_evaluation"]["reviewed_attempt_candidates"] == 1


@pytest.mark.parametrize(
    "patch",
    [
        {"is_shot": "yes"},
        {"shot_outcome": "nope"},
        {"is_scoring": True},
        {"is_shot": False, "shot_outcome": None},
        {"shooter_track_id": True},
        {"shooter_track_id": 0},
        {"player_id": ""},
    ],
)
def test_invalid_or_contradictory_attempt_labels_rejected(patch):
    with pytest.raises(ValueError):
        normalize_shot_label({**label(0, "missed", 1), **patch})


def test_stale_scopes_cannot_inflate_attempt_metrics():
    stale = {**label(0, "made", 1), "tracking_scope": "old"}
    report = evaluate_attempts(scene(), [stale])
    assert report["reviewed_attempt_candidates"] == 0
    assert report["stale_or_unmatched_labels"] == ["0"]


def test_field_goal_sample_requires_explicit_identity_and_deduplicates_attempts():
    labels = [
        {**label(0, "made", 1), "player_id": "alice", "attempt_id": "shot-a"},
        {**label(1, "made", 2), "player_id": "alice", "attempt_id": "shot-a"},
        {**label(2, "missed", 1), "player_id": "alice", "attempt_id": "shot-b"},
        label(0, "made", 1),
    ]
    report = summarize_linked_field_goals(labels)
    assert report["players"] == [
        {"player_id": "alice", "fgm": 1, "fga": 2, "sample_fg_percent": 50}
    ]
    assert report["labels_missing_player_or_attempt_identity"] == 1
    assert report["full_game_fg_percent"] is None


def test_conflicting_outcome_or_owner_excluded_from_field_goal_denominator():
    labels = [
        {**label(0, "made", 1), "player_id": "alice", "attempt_id": "shot-a"},
        {**label(1, "missed", 2), "player_id": "alice", "attempt_id": "shot-a"},
        {**label(0, "made", 1), "player_id": "alice", "attempt_id": "shot-b"},
        {**label(1, "made", 2), "player_id": "bob", "attempt_id": "shot-b"},
    ]
    report = summarize_linked_field_goals(labels)
    assert report["players"] == []
    assert report["conflicting_attempt_ids"] == ["shot-a", "shot-b"]
