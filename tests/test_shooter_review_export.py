import copy

import pytest
from export_shooter_review_dataset import analyze_review


def fixture():
    outcomes = [
        ("made", "made"),
        ("made", "missed"),
        ("unknown", "made"),
        ("missed", "missed"),
    ]
    results, labels = [], []
    for i, (machine, human) in enumerate(outcomes):
        results.append(
            {
                "candidate_id": str(i),
                "tracking_scope": "s",
                "event_time_ms": i * 1000,
                "status": "attributed" if i < 3 else "unknown",
                "shooter": {"track_id": 1} if i < 3 else None,
                "reason": "fixture",
                "outcome_prediction": {
                    "shot_outcome": machine,
                    "rim_check": {"status": "fixture"},
                },
            }
        )
        labels.append(
            {
                "candidate_id": str(i),
                "tracking_scope": "s",
                "is_shot": True,
                "shot_outcome": human,
                "shooter_track_id": 2 if i == 1 else 1,
            }
        )
    return {"results": results}, labels


def test_export_separates_outcome_corrections_abstentions_and_shooter_truth():
    predictions, labels = fixture()
    original = copy.deepcopy((predictions, labels))
    metrics, rows, errors, unknowns = analyze_review(predictions, labels)
    assert metrics["outcome"]["accuracy_on_decided"] == 2 / 3
    assert metrics["outcome"]["decision_coverage"] == 3 / 4
    assert metrics["outcome"]["correct_fraction_of_all_reviewed"] == 2 / 4
    assert metrics["outcome"]["wrong_decisions"] == 1
    assert metrics["outcome"]["abstentions"] == 1
    assert metrics["shooter"]["precision"] == 2 / 3
    assert [row["candidate_id"] for row in errors] == ["1"]
    assert [row["candidate_id"] for row in unknowns] == ["3"]
    assert [row["correction_kind"] for row in rows] == [
        "confirmed",
        "wrong_decision",
        "resolved_abstention",
        "confirmed",
    ]
    assert not any("shooter_track_id" in row or "tracking_scope" in row for row in rows)
    assert (predictions, labels) == original


@pytest.mark.parametrize("kind", ["missing", "stale", "duplicate"])
def test_export_requires_exact_complete_unique_human_review(kind):
    predictions, labels = fixture()
    if kind == "missing":
        labels.pop()
    elif kind == "stale":
        labels[0]["tracking_scope"] = "other"
    else:
        labels.append(labels[0])
    with pytest.raises(ValueError, match="REVIEW_"):
        analyze_review(predictions, labels)


def test_non_shot_does_not_become_a_missed_attempt_or_outcome_error():
    predictions, labels = fixture()
    labels[0].update(is_shot=False, shot_outcome=None, shooter_track_id=None)
    metrics, rows, _, _ = analyze_review(predictions, labels)
    assert metrics["outcome"]["reviewed_binary_outcomes"] == 3
    assert rows[0]["correction_kind"] == "false_candidate"
    assert metrics["shooter"]["explicit_non_shot_candidates"] == 1
