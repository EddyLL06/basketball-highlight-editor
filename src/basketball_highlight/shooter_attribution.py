"""Pure candidate adaptation and shooter ranking; no video or ML imports."""

from __future__ import annotations

import json
import math
from collections.abc import Mapping
from dataclasses import dataclass

from .shot_release import ShotReleaseEstimator

METHOD = "possession_trajectory_v1"
SCHEMA_VERSION = 1


@dataclass(frozen=True)
class ScoringEvent:
    candidate_id: str
    timestamp: float
    rim: dict | None = None


def load_scoring_events(payload) -> list[ScoringEvent]:
    """Accept BHE coarse/refined artifacts, engine rows or a candidate list.

    Native `time` is seconds; `event_time_ms` / `event_ms` are milliseconds.
    Inputs are never mutated. Existing candidate IDs are retained verbatim.
    """
    inherited_rim = payload.get("rim") if isinstance(payload, Mapping) else None
    if isinstance(payload, Mapping) and "results" in payload:
        rows = [
            match
            for result in payload["results"]
            for match in result.get("refined", [])
        ]
    elif isinstance(payload, Mapping):
        rows = payload.get("candidates", [payload])
    else:
        rows = payload
    if not isinstance(rows, list):
        raise ValueError("ATTRIBUTION_CANDIDATES_INVALID")
    events = []
    for index, row in enumerate(rows):
        if not isinstance(row, Mapping):
            raise ValueError("ATTRIBUTION_CANDIDATE_INVALID")
        try:
            timestamp = (
                float(row["event_time_ms"]) / 1000
                if "event_time_ms" in row
                else float(row["event_ms"]) / 1000
                if "event_ms" in row
                else float(row["time"])
            )
            if not math.isfinite(timestamp) or timestamp < 0:
                raise ValueError
            evidence = row.get("evidence_json", {})
            if isinstance(evidence, str):
                evidence = json.loads(evidence)
            overlay = row.get("overlay") or evidence.get("overlay") or {}
            rim = overlay.get("rim") or row.get("rim") or inherited_rim
            if rim:
                rim = {key: float(rim[key]) for key in ("center_x", "rim_y", "width")}
                if not all(math.isfinite(v) for v in rim.values()) or rim["width"] <= 0:
                    raise ValueError
            candidate_id = str(
                row.get("candidate_id")
                or row.get("id")
                or f"candidate_{index:06d}_{round(timestamp * 1000)}"
            )
        except (KeyError, TypeError, ValueError, AttributeError) as exc:
            raise ValueError(f"ATTRIBUTION_CANDIDATE_INVALID: row {index}") from exc
        events.append(ScoringEvent(candidate_id, timestamp, rim))
    if len({e.candidate_id for e in events}) != len(events):
        raise ValueError("ATTRIBUTION_DUPLICATE_CANDIDATE_ID")
    return events


class ShooterAttributor:
    def __init__(
        self,
        *,
        min_score=0.78,
        min_margin=0.12,
        min_track_reliability=0.55,
        release_estimator=None,
    ):
        if any(
            not math.isfinite(v) or not 0 <= v <= 1
            for v in (min_score, min_margin, min_track_reliability)
        ):
            raise ValueError("ATTRIBUTION_THRESHOLDS_INVALID")
        self.min_score, self.min_margin = min_score, min_margin
        self.min_track_reliability = min_track_reliability
        self.release_estimator = release_estimator or ShotReleaseEstimator()

    def attribute(
        self, event, ball_track, player_tracks, *, tracking_scope, sample_fps=12
    ):
        result = {
            "candidate_id": event.candidate_id,
            "event_time_ms": round(event.timestamp * 1000),
            "tracking_scope": tracking_scope,
            "status": "unknown",
            "shooter": None,
            "method": METHOD,
            "score_kind": "heuristic_not_calibrated",
            "reason": None,
            "rankings": [],
        }
        if not ball_track.observations:
            result["reason"] = ball_track.reason or "ball_trajectory_missing"
            return result
        if ball_track.ambiguous:
            result["reason"] = "ambiguous_ball_path"
            return result
        if not player_tracks:
            result["reason"] = "no_player_tracks"
            return result
        hypotheses = self.release_estimator.estimate(
            ball_track, player_tracks, event.timestamp, sample_fps=sample_fps
        )
        result["rankings"] = [h.to_dict() for h in hypotheses]
        if not hypotheses:
            result["reason"] = "release_not_observed"
            return result
        best = hypotheses[0]
        reason = None
        if best.evidence["tracking_ambiguous"]:
            reason = "ambiguous_player_tracking"
        elif best.evidence["track_reliability"] < self.min_track_reliability:
            reason = "unreliable_player_track"
        elif best.score < self.min_score:
            reason = "score_below_threshold"
        elif len(hypotheses) > 1 and best.score - hypotheses[1].score < self.min_margin:
            reason = "multiple_plausible_shooters"
        if reason:
            result["reason"] = reason
        else:
            result.update(
                status="attributed", reason="supported_release", shooter=best.to_dict()
            )
        return result
