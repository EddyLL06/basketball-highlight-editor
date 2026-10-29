"""Export an immutable local review snapshot with separate outcome-only labels."""

import argparse
import csv
import hashlib
import json
import shutil
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from basketball_highlight.shooter_evaluation import evaluate_attempts
from basketball_highlight.shooter_labels import normalize_shot_label


def analyze_review(predictions, labels):
    results = predictions["results"]
    by_key = {(r["candidate_id"], r["tracking_scope"]): r for r in results}
    truth = {
        (l["candidate_id"], l["tracking_scope"]): normalize_shot_label(l)
        for l in labels
    }
    if len(by_key) != len(results) or len(truth) != len(labels):
        raise ValueError("REVIEW_DUPLICATE_ID_OR_SCOPE")
    if set(truth) != set(by_key):
        raise ValueError("REVIEW_REQUIRES_COMPLETE_EXACT_SCOPE_LABELS")
    rows, shooter_errors, unknown_shooters = [], [], []
    confusion = {
        actual: {p: 0 for p in ("made", "missed", "unknown")}
        for actual in ("made", "missed")
    }
    for key, result in by_key.items():
        label = truth[key]
        prediction = result["outcome_prediction"]
        machine = prediction["shot_outcome"]
        if machine not in ("made", "missed", "unknown"):
            raise ValueError("REVIEW_INVALID_MACHINE_OUTCOME")
        actual = label["shot_outcome"]
        eligible = label["is_shot"] is True and actual in ("made", "missed")
        if eligible:
            confusion[actual][machine] += 1
        kind = (
            "false_candidate"
            if label["is_shot"] is False
            else "human_outcome_unresolved"
            if not eligible
            else "resolved_abstention"
            if machine == "unknown"
            else "confirmed"
            if machine == actual
            else "wrong_decision"
        )
        # No shooter identity is required to train or evaluate the outcome task.
        rows.append(
            {
                "candidate_id": key[0],
                "event_time_ms": result["event_time_ms"],
                "is_shot": label["is_shot"],
                "human_outcome": actual,
                "engine_outcome": machine,
                "correction_kind": kind,
                "engine_rim_check": prediction["rim_check"],
                "review_note": label.get("note", ""),
                "label_source": "human_saved_review",
            }
        )
        predicted = (
            result["shooter"]["track_id"] if result["status"] == "attributed" else None
        )
        shooter_row = {
            "candidate_id": key[0],
            "event_time_ms": result["event_time_ms"],
            "tracking_scope": key[1],
            "predicted_track_id": predicted,
            "human_track_id": label.get("shooter_track_id"),
            "reason": result["reason"],
            "human_outcome": actual,
            "review_note": label.get("note", ""),
        }
        if predicted is None and label["is_shot"] is True:
            unknown_shooters.append(shooter_row)
        elif (
            label.get("shooter_track_id") is not None
            and predicted != label["shooter_track_id"]
        ):
            shooter_errors.append(shooter_row)
    total = sum(sum(row.values()) for row in confusion.values())
    decided = sum(row["made"] + row["missed"] for row in confusion.values())
    correct = confusion["made"]["made"] + confusion["missed"]["missed"]
    made_predictions = sum(row["made"] for row in confusion.values())
    missed_predictions = sum(row["missed"] for row in confusion.values())
    outcome = {
        "scope": "human_classified_candidate_anchors_not_unique_physical_attempts",
        "reviewed_binary_outcomes": total,
        "decided": decided,
        "correct": correct,
        "wrong_decisions": decided - correct,
        "abstentions": total - decided,
        "decision_coverage": decided / total if total else None,
        "accuracy_on_decided": correct / decided if decided else None,
        "correct_fraction_of_all_reviewed": correct / total if total else None,
        "made_precision": confusion["made"]["made"] / made_predictions
        if made_predictions
        else None,
        "missed_precision": confusion["missed"]["missed"] / missed_predictions
        if missed_predictions
        else None,
        "confusion_actual_rows_predicted_columns": confusion,
        "correction_kinds": dict(Counter(r["correction_kind"] for r in rows)),
        "exhaustive_shot_recall_and_physical_deduplication_unverified": True,
    }
    return (
        {"shooter": evaluate_attempts(predictions, labels), "outcome": outcome},
        rows,
        shooter_errors,
        unknown_shooters,
    )


def write_json(path, value):
    path.write_text(
        json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False),
        encoding="utf-8",
    )


def write_rows(path, rows):
    path.write_text(
        "".join(
            json.dumps(row, ensure_ascii=False, allow_nan=False) + "\n" for row in rows
        ),
        encoding="utf-8",
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument("--labels", type=Path, required=True)
    parser.add_argument(
        "--output", type=Path, required=True, help="A new, private directory"
    )
    args = parser.parse_args()
    predictions = json.loads(args.predictions.read_text(encoding="utf-8"))
    labels = json.loads(args.labels.read_text(encoding="utf-8"))
    metrics, rows, errors, unknowns = analyze_review(predictions, labels)
    args.output.mkdir(parents=True, exist_ok=False)
    source = args.output / "source"
    source.mkdir()
    shutil.copy2(args.labels, source / "human-labels-original.json")
    shutil.copy2(args.predictions, source / "predictions-with-outcomes-original.json")
    write_json(args.output / "metrics.json", metrics)
    write_rows(args.output / "outcomes-reviewed.jsonl", rows)
    write_rows(
        args.output / "outcomes-corrections.jsonl",
        [r for r in rows if r["correction_kind"] == "wrong_decision"],
    )
    write_rows(
        args.output / "outcomes-resolved-unknown.jsonl",
        [r for r in rows if r["correction_kind"] == "resolved_abstention"],
    )
    write_json(args.output / "shooter-errors.json", errors)
    write_json(args.output / "shooter-unknowns.json", unknowns)
    flat = [{k: v for k, v in row.items() if k != "engine_rim_check"} for row in rows]
    with (args.output / "outcomes-reviewed.csv").open(
        "w", encoding="utf-8-sig", newline=""
    ) as stream:
        writer = csv.DictWriter(
            stream, fieldnames=list(flat[0]) if flat else ["candidate_id"]
        )
        writer.writeheader()
        writer.writerows(flat)
    write_json(
        args.output / "input-sha256.json",
        {
            "predictions": hashlib.sha256(args.predictions.read_bytes()).hexdigest(),
            "human_labels": hashlib.sha256(args.labels.read_bytes()).hexdigest(),
            "machine_suggestions_are_not_human_labels": True,
        },
    )
    print(json.dumps(metrics, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
