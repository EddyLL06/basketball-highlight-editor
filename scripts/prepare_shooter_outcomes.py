"""Add BHE engine outcome suggestions to a copy of frozen shooter predictions."""

import argparse
import copy
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "engine/python"))
from basketball_engine.adapters.analysis import apply_rim_checks, rim_check_inputs
from basketball_highlight.shooter_attribution import load_scoring_events


def attach_outcomes(predictions, candidates, rim_checks):
    """Reuse the desktop engine verdict policy without creating human labels."""
    items = candidates["candidates"]
    results = predictions["results"]
    if len(items) != len(results) or len(rim_checks.get("results", [])) != len(items):
        raise ValueError("OUTCOME_CANDIDATE_COUNT_MISMATCH")
    ids = [c["id"] for c in items]
    if len(set(ids)) != len(ids) or set(ids) != {r["candidate_id"] for r in results}:
        raise ValueError("OUTCOME_CANDIDATE_ID_MISMATCH")
    source_video = Path(rim_checks["video"])
    if (
        candidates.get("video")
        and source_video.resolve() != Path(candidates["video"]).resolve()
    ):
        raise ValueError("OUTCOME_VIDEO_MISMATCH")
    fingerprint = predictions.get("video_fingerprint")
    if fingerprint:
        # Shooter archives intentionally store only the basename. Verify the
        # original file identity instead of comparing that name with a full path.
        stat = source_video.stat()
        actual = {
            "name": source_video.name,
            "size": stat.st_size,
            "mtime_ns": stat.st_mtime_ns,
        }
        if actual != fingerprint or Path(predictions["video"]).name != actual["name"]:
            raise ValueError("OUTCOME_VIDEO_MISMATCH")
    elif source_video.resolve() != Path(predictions["video"]).resolve():
        raise ValueError("OUTCOME_VIDEO_MISMATCH")
    by_id = {r["candidate_id"]: r for r in results}
    event_times = {
        event.candidate_id: event.timestamp * 1000
        for event in load_scoring_events(candidates)
    }
    matches = []
    for candidate in items:
        if (
            abs(event_times[candidate["id"]] - by_id[candidate["id"]]["event_time_ms"])
            > 1
        ):
            raise ValueError("OUTCOME_EVENT_TIME_MISMATCH")
        source = candidate.get("anchor_source")
        if source not in ("existing_refined", "existing_coarse_fallback"):
            raise ValueError("OUTCOME_REFINEMENT_PROVENANCE_MISSING")
        matches.append(
            {
                "time": candidate["time"],
                "overlay": {"rim": copy.deepcopy(candidate.get("rim"))},
                "coarse_crossing": source == "existing_coarse_fallback",
            }
        )
    # This includes the video-wide occlusion rule and keep-unless-seen policy.
    # The verifier's raw "rejected" verdict alone does not prove a miss.
    apply_rim_checks(matches, rim_check_inputs(matches), rim_checks)
    enriched = copy.deepcopy(predictions)
    checks = {
        candidate["id"]: match["rim_check"] for candidate, match in zip(items, matches)
    }
    for result in enriched["results"]:
        check = checks[result["candidate_id"]]
        result["outcome_prediction"] = {
            "source": "bhe_desktop_rim_check",
            "shot_outcome": {"made": "made", "rejected": "missed"}.get(
                check["status"], "unknown"
            ),
            "human_confirmed": False,
            "attempt_requires_review": True,
            "rim_check": check,
        }
    return enriched


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument("--candidates", type=Path, required=True)
    parser.add_argument("--rim-checks", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    sources = [args.predictions, args.candidates, args.rim_checks]
    if args.output.resolve() in {p.resolve() for p in sources}:
        parser.error("Write a separate enriched output; preserve source artifacts")
    data = [json.loads(path.read_text(encoding="utf-8")) for path in sources]
    enriched = attach_outcomes(*data)
    enriched["outcome_analysis"] = {
        "source": "bhe_desktop_rim_check",
        "inputs": {
            path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sources
        },
        "detector_seconds": data[2].get("elapsed_seconds"),
        "human_labels_created": 0,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_name(f".{args.output.name}.tmp")
    temporary.write_text(
        json.dumps(enriched, indent=2, ensure_ascii=False, allow_nan=False),
        encoding="utf-8",
    )
    temporary.replace(args.output)
    from collections import Counter

    print(
        dict(
            Counter(
                r["outcome_prediction"]["shot_outcome"] for r in enriched["results"]
            )
        )
    )


if __name__ == "__main__":
    main()
