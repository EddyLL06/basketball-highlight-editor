"""Diagnostic replay after removing ball observations outside an ROI.

This is an observation-support ablation, not detector re-inference: it does not
measure the resolution/recall effects of changing the model's input crop.
"""

import argparse
import copy
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from basketball_highlight.attribution_video import (
    AnalysisConfig,
    ShooterAttributionPipeline,
)
from basketball_highlight.rim_check import tight_crop_box
from basketball_highlight.shooter_attribution import load_scoring_events
from basketball_highlight.shooter_evaluation import (
    build_spatial_references,
    evaluate_spatial_references,
)
from basketball_highlight.shooter_observations import ObservationArchive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument("--observations", type=Path, required=True)
    parser.add_argument("--candidates", type=Path, required=True)
    parser.add_argument("--labels", type=Path, required=True)
    parser.add_argument("--roi", nargs=4, type=float, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    baseline = json.loads(args.predictions.read_text())
    payload = json.loads(args.observations.read_text())
    candidates = json.loads(args.candidates.read_text())
    labels = json.loads(args.labels.read_text())
    references = build_spatial_references(baseline, labels)
    events = load_scoring_events(candidates)
    config = AnalysisConfig(**baseline["config"])
    w, h = baseline["frame_width"], baseline["frame_height"]
    left, top, right, bottom = args.roi
    if not 0 <= left < right <= w or not 0 <= top < bottom <= h:
        raise ValueError("ROI_ABLATION_INVALID_REGION")
    rim = candidates["candidates"][0]["rim"]
    rois = {
        "full_observations": [0, 0, w, h],
        "bhe_analysis_roi": args.roi,
        "rim_tight_roi": tight_crop_box(rim, w, h),
    }
    original_by_id = {r["candidate_id"]: r for r in baseline["results"]}
    reports = {}
    for name, (x1, y1, x2, y2) in rois.items():
        filtered = copy.deepcopy(payload)
        removed = 0
        for frame in filtered["frames"]:
            balls = frame["balls"]
            frame["balls"] = [
                b
                for b in balls
                if x1 <= (b["bbox"][0] + b["bbox"][2]) / 2 <= x2
                and y1 <= (b["bbox"][1] + b["bbox"][3]) / 2 <= y2
            ]
            removed += len(balls) - len(frame["balls"])
        pipeline = ShooterAttributionPipeline(
            None, None, config=config, algorithm=baseline["analysis_algorithm"]
        )
        result = pipeline.analyze(
            args.video,
            events,
            observation_archive=ObservationArchive(filtered, args.video),
        )
        changed = []
        changed_scopes = 0
        for row in result["results"]:
            before = original_by_id[row["candidate_id"]]
            if name == "full_observations":
                for key in (
                    "tracking_scope",
                    "status",
                    "reason",
                    "shooter",
                    "ball_trajectory",
                ):
                    assert row[key] == before[key], f"Baseline replay differs: {key}"
            changed_scopes += row["tracking_scope"] != before["tracking_scope"]
            if row["status"] != before["status"] or row["shooter"] != before["shooter"]:
                changed.append(
                    {
                        "candidate_id": row["candidate_id"],
                        "event_time_ms": row["event_time_ms"],
                        "before_track": before["shooter"]["track_id"]
                        if before["shooter"]
                        else None,
                        "after_track": row["shooter"]["track_id"]
                        if row["shooter"]
                        else None,
                        "after_reason": row["reason"],
                    }
                )
        evaluation = evaluate_spatial_references(result, references)
        reports[name] = {
            "roi_xyxy": [x1, y1, x2, y2],
            "removed_ball_observations": removed,
            "metrics": evaluation["attempt_evaluation"],
            "changed_scopes_from_automatic_window_expansion": changed_scopes,
            "reference_matches": evaluation["reference_matches"],
            "changed_results": changed,
        }
    report = {
        "experiment": "post_detection_observation_support_ablation",
        "not_a_crop_detector_accuracy_comparison": True,
        "same_archived_frames_players_models_algorithm_thresholds": True,
        "automatic_window_expansion_can_change_tracking_context": True,
        "human_track_truth_transferred_by_spatial_references_not_raw_ids": True,
        "all_51_q3_candidates_are_now_development_data": True,
        "variants": reports,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(
        json.dumps(
            {
                name: {
                    "removed": r["removed_ball_observations"],
                    "assigned": r["metrics"]["attributed_attempts"],
                    "correct": r["metrics"]["correct_predictions"],
                    "precision": r["metrics"]["precision"],
                    "coverage": r["metrics"]["coverage"],
                }
                for name, r in reports.items()
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
