"""Human-label evaluation; unknown/unreviewed labels never become successes."""

from __future__ import annotations

import statistics

from .player_tracking import bbox_iou
from .shooter_labels import normalize_shot_label, summarize_linked_field_goals


def evaluate_shooters(predictions, labels):
    results = predictions["results"]
    by_key = {(r["candidate_id"], r["tracking_scope"]): r for r in results}
    if len(by_key) != len(results):
        raise ValueError("ATTRIBUTION_DUPLICATE_RESULT")
    seen, scored, resolvable, invalid, not_scoring = set(), [], [], [], 0
    attributed_non_scoring = 0
    for label in labels:
        key = (label["candidate_id"], label["tracking_scope"])
        if key in seen:
            raise ValueError("ATTRIBUTION_DUPLICATE_LABEL")
        seen.add(key)
        if key not in by_key:
            invalid.append(label["candidate_id"])
            continue
        label = normalize_shot_label(label)
        result = by_key[key]
        if label.get("is_scoring") is False:
            not_scoring += 1
            attributed_non_scoring += result["status"] == "attributed"
            continue
        if label.get("is_scoring") is not True:
            continue
        scored.append(result)
        if label.get("shooter_track_id") is not None:
            expected = label["shooter_track_id"]
            if not isinstance(expected, int) or isinstance(expected, bool):
                raise ValueError("ATTRIBUTION_LABEL_TRACK_INVALID")
            resolvable.append((result, expected))
    assigned = [r for r in scored if r["status"] == "attributed"]
    evaluated_predictions = [
        (r, expected) for r, expected in resolvable if r["status"] == "attributed"
    ]
    correct = sum(
        r["shooter"]["track_id"] == expected for r, expected in evaluated_predictions
    )
    times = [r["processing_seconds"] for r in scored if "processing_seconds" in r]
    bins = []
    for lower, upper in ((0, 0.6), (0.6, 0.7), (0.7, 0.8), (0.8, 0.9), (0.9, 1.01)):
        subset = [
            (r, expected)
            for r, expected in evaluated_predictions
            if lower <= r["shooter"]["score"] < upper
        ]
        bins.append(
            {
                "score_range": [lower, min(upper, 1)],
                "predictions": len(subset),
                "precision": sum(r["shooter"]["track_id"] == e for r, e in subset)
                / len(subset)
                if subset
                else None,
            }
        )
    report = {
        "reviewed_scoring_events": len(scored),
        "ground_truth_resolvable_events": len(resolvable),
        "non_scoring_candidates": not_scoring,
        "attributions_on_non_scoring_candidates": attributed_non_scoring,
        "assigned_reviewed_candidates": len(assigned) + attributed_non_scoring,
        "unreviewed_events": len(results) - len(seen & by_key.keys()),
        "stale_or_unmatched_labels": invalid,
        "attributed_events": len(assigned),
        "correct_predictions": correct,
        "precision_denominator": len(evaluated_predictions),
        "precision": correct / len(evaluated_predictions)
        if evaluated_predictions
        else None,
        "coverage": len(assigned) / len(scored) if scored else None,
        "unknown_rate": (len(scored) - len(assigned)) / len(scored) if scored else None,
        "predictions_without_resolvable_truth": len(assigned)
        - len(evaluated_predictions),
        "mean_seconds_per_candidate": statistics.mean(times) if times else None,
        "median_seconds_per_candidate": statistics.median(times) if times else None,
        "score_bins": bins,
        "score_kind": "heuristic_not_calibrated",
        "performance": predictions.get("performance", {}),
        "metric_scope": "made_baskets_only_legacy",
    }
    report["attempt_evaluation"] = evaluate_attempts(predictions, labels)
    return report


def evaluate_attempts(predictions, labels):
    """Evaluate the releaser on made AND missed attempts, separately from outcome."""
    results = predictions["results"]
    by_key = {(r["candidate_id"], r["tracking_scope"]): r for r in results}
    if len(by_key) != len(results):
        raise ValueError("ATTRIBUTION_DUPLICATE_RESULT")
    seen, valid, stale = set(), [], []
    for raw in labels:
        key = (raw["candidate_id"], raw["tracking_scope"])
        if key in seen:
            raise ValueError("ATTRIBUTION_DUPLICATE_LABEL")
        seen.add(key)
        if key not in by_key:
            stale.append(raw["candidate_id"])
            continue
        valid.append((by_key[key], normalize_shot_label(raw)))
    attempts = [(r, l) for r, l in valid if l["is_shot"] is True]

    def metrics(rows):
        assigned = [(r, l) for r, l in rows if r["status"] == "attributed"]
        verifiable = [
            (r, l) for r, l in assigned if l.get("shooter_track_id") is not None
        ]
        correct = sum(
            r["shooter"]["track_id"] == l["shooter_track_id"] for r, l in verifiable
        )
        return {
            "reviewed_attempt_candidates": len(rows),
            "attributed_attempts": len(assigned),
            "correct_predictions": correct,
            "precision_denominator": len(verifiable),
            "precision": correct / len(verifiable) if verifiable else None,
            "coverage": len(assigned) / len(rows) if rows else None,
            "unknown_attempts": len(rows) - len(assigned),
            "assignments_without_resolvable_truth": len(assigned) - len(verifiable),
        }

    return {
        **metrics(attempts),
        "metric_scope": "reviewed_made_and_missed_attempt_candidates",
        "reviewed_candidates": len(valid),
        "unreviewed_candidates": len(results) - len(seen & by_key.keys()),
        "stale_or_unmatched_labels": stale,
        "by_outcome": {
            outcome: metrics(
                [(r, l) for r, l in attempts if l["shot_outcome"] == outcome]
            )
            for outcome in ("made", "missed", "unknown")
        },
        "explicit_non_shot_candidates": sum(l["is_shot"] is False for _, l in valid),
        "attributions_on_explicit_non_shots": sum(
            l["is_shot"] is False and r["status"] == "attributed" for r, l in valid
        ),
        "unclassified_legacy_not_made_candidates": sum(
            l["is_shot"] is None for _, l in valid
        ),
        "linked_field_goal_sample": summarize_linked_field_goals([l for _, l in valid]),
        "candidate_recall_and_physical_attempt_deduplication_unverified": True,
    }


def build_spatial_references(predictions, labels):
    """Freeze human-selected player boxes before a tracker renumbers its IDs.

    References remain within this exact video/event. They are evaluation labels,
    never production player enrollment or cross-clip identity matching.
    """
    by_key = {
        (r["candidate_id"], r["tracking_scope"]): r for r in predictions["results"]
    }
    sessions = {s["tracking_scope"]: s for s in predictions["sessions"]}
    events = []
    for label in labels:
        key = (label["candidate_id"], label["tracking_scope"])
        if key not in by_key:
            raise ValueError("ATTRIBUTION_REFERENCE_STALE_LABEL")
        result = by_key[key]
        anchors = []
        track_id = label.get("shooter_track_id")
        if track_id is not None and label.get("review_kind") != "event_only":
            track = next(
                t
                for t in sessions[result["tracking_scope"]]["tracks"]
                if t["track_id"] == track_id
            )
            leading = result.get("shooter") or next(
                iter(result.get("rankings", [])), None
            )
            reference_time = (
                leading["release_interval_ms"][0] / 1000
                if leading
                else max(0, result["event_time_ms"] / 1000 - 1.2)
            )
            observations = [
                d
                for d in track["observations"]
                if reference_time - 0.6 <= d["timestamp"] <= reference_time + 0.4
            ]
            if len(observations) >= 3:
                indices = sorted(
                    {round(i * (len(observations) - 1) / 4) for i in range(5)}
                )
                anchors = [
                    {
                        "timestamp": observations[i]["timestamp"],
                        "bbox": observations[i]["bbox"],
                    }
                    for i in indices
                ]
        events.append(
            {
                "candidate_id": result["candidate_id"],
                "event_time_ms": result["event_time_ms"],
                "is_scoring": label["is_scoring"],
                "shooter_anchors": anchors,
                "source_tracking_scope": label["tracking_scope"],
                "source_track_id": track_id,
                "note": label.get("note", ""),
                **{
                    k: label[k]
                    for k in ("is_shot", "shot_outcome", "player_id", "attempt_id")
                    if k in label
                },
            }
        )
    return {
        "schema_version": 2,
        "label_kind": "human_selected_player_spatial_anchors",
        "video_fingerprint": predictions["video_fingerprint"],
        "events": events,
    }


def evaluate_spatial_references(predictions, references):
    if references.get("schema_version") != 2 or references.get(
        "video_fingerprint"
    ) != predictions.get("video_fingerprint"):
        raise ValueError("ATTRIBUTION_REFERENCE_VIDEO_MISMATCH")
    by_id = {r["candidate_id"]: r for r in predictions["results"]}
    sessions = {s["tracking_scope"]: s for s in predictions["sessions"]}
    labels, matches = [], []
    for reference in references["events"]:
        result = by_id.get(reference["candidate_id"])
        if result is None:
            continue
        if result["event_time_ms"] != reference["event_time_ms"]:
            raise ValueError("ATTRIBUTION_REFERENCE_EVENT_MISMATCH")
        scores = []
        anchors = reference.get("shooter_anchors", [])
        if anchors:
            for track in sessions[result["tracking_scope"]]["tracks"]:
                overlaps = []
                for anchor in anchors:
                    nearest = min(
                        track["observations"],
                        key=lambda d: abs(d["timestamp"] - anchor["timestamp"]),
                        default=None,
                    )
                    overlaps.append(
                        bbox_iou(anchor["bbox"], nearest["bbox"])
                        if nearest
                        and abs(nearest["timestamp"] - anchor["timestamp"]) <= 0.1
                        else 0
                    )
                scores.append((sum(overlaps) / len(overlaps), track["track_id"]))
        scores.sort(reverse=True)
        best = scores[0][0] if scores else 0
        margin = best - (scores[1][0] if len(scores) > 1 else 0)
        expected = scores[0][1] if scores and best >= 0.5 and margin >= 0.15 else None
        labels.append(
            {
                "candidate_id": result["candidate_id"],
                "tracking_scope": result["tracking_scope"],
                "is_scoring": reference["is_scoring"],
                "shooter_track_id": expected,
                **{
                    k: reference[k]
                    for k in ("is_shot", "shot_outcome", "player_id", "attempt_id")
                    if k in reference
                },
            }
        )
        matches.append(
            {
                "candidate_id": result["candidate_id"],
                "expected_track_id": expected,
                "mean_reference_iou": best,
                "reference_match_margin": margin,
                "reference_anchors": len(anchors),
                "predicted_track_id": result["shooter"]["track_id"]
                if result["shooter"]
                else None,
            }
        )
    report = evaluate_shooters(predictions, labels)
    report["reference_matches"] = matches
    report["evaluation_kind"] = "same_video_human_spatial_references"
    return report
