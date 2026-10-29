"""Bounded ball hypotheses evaluated jointly with player release evidence.

An uncertain detection before possession does not automatically invalidate an
otherwise observed release. Competing credible releasers still cause abstention.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, replace

from .ball_possession import BallTrajectory
from .shooter_attribution import ShooterAttributor
from .shot_release import ShotReleaseEstimator
from .trajectory_gaps import top_boundary_bridge


@dataclass
class PathHypothesis:
    points: list
    cost: float
    skipped: int = 0

    @property
    def mean_cost(self):
        return self.cost / max(1, len(self.points) + self.skipped)


def ball_path_hypotheses(
    frames,
    event_time,
    frame_size,
    *,
    rim=None,
    max_gap=0.35,
    min_confidence=0.1,
    beam_width=12,
    max_paths=6,
    allow_out_of_frame=False,
):
    """Backward beam search over observed points, with explicit missing samples.

    Gates use elapsed source time, frame-diagonal speed and ball-scale residuals.
    All near-event frames are searched for a valid anchor, so an unrelated ball
    in the closest sampled frame cannot mask valid rim evidence one frame away.
    """
    grouped = {}
    for timestamp, detections in frames:
        if timestamp <= event_time + 0.35:
            grouped.setdefault(timestamp, set()).update(
                d for d in detections if d.confidence >= min_confidence
            )
    times = sorted(grouped)
    diagonal = math.hypot(*frame_size)
    anchors = []
    for timestamp in times:
        if abs(timestamp - event_time) > max(0.5, max_gap):
            continue
        for point in grouped[timestamp]:
            if rim:
                distance = math.dist(point.center, (rim["center_x"], rim["rim_y"]))
                if distance > max(3 * rim["width"], diagonal * 0.03):
                    continue
                cost = distance / rim["width"] * 0.2
            else:
                cost = 0
            anchors.append(
                (
                    cost
                    + abs(timestamp - event_time) * 0.8
                    - math.log(max(point.confidence, 0.001)),
                    point,
                )
            )
    if not anchors:
        return []
    anchors.sort(key=lambda pair: (pair[0], pair[1].timestamp, pair[1].bbox))
    states = [PathHypothesis([point], cost) for cost, point in anchors[:max_paths]]
    finished = []
    for timestamp in reversed(times):
        expanded = []
        for state in states:
            last = state.points[-1]
            if timestamp >= last.timestamp - 1e-6:
                expanded.append(state)
                continue
            gap = last.timestamp - timestamp
            extend_edge = (
                allow_out_of_frame
                and gap <= 0.85
                and len(state.points) >= 3
                and last.center[1] <= frame_size[1] * 0.1
            )
            if gap > max_gap + 1e-6 and not extend_edge:
                finished.append(state)
                continue
            expected = last.center
            if len(state.points) > 1:
                following = state.points[-2]
                dt = following.timestamp - last.timestamp
                expected = tuple(
                    last.center[i] + (last.center[i] - following.center[i]) * gap / dt
                    for i in (0, 1)
                )
            options = []
            for point in grouped[timestamp]:
                if (
                    gap > max_gap + 1e-6
                    and top_boundary_bridge(
                        point, state.points[-3:], grouped, frame_size
                    )
                    is None
                ):
                    continue
                size = max(last.height, last.bbox[2] - last.bbox[0], point.height)
                distance, residual = (
                    math.dist(point.center, last.center),
                    math.dist(point.center, expected),
                )
                if not 0.3 <= point.height / last.height <= 3.3:
                    continue
                if distance > diagonal * 2 * gap + size * 2 or residual > max(
                    size * 3.5, diagonal * 0.7 * gap
                ):
                    continue
                # Smooth trajectories accumulate support; one low-score hand-like
                # blob can be skipped rather than changing the entire ball path.
                cost = -math.log(max(point.confidence, 0.001)) + 0.4 * min(
                    residual / size, 4
                )
                options.append((cost, point))
            for cost, point in sorted(
                options, key=lambda pair: (pair[0], pair[1].bbox)
            )[:3]:
                expanded.append(
                    PathHypothesis(
                        state.points + [point], state.cost + cost, state.skipped
                    )
                )
            expanded.append(
                PathHypothesis(state.points, state.cost + 2.2, state.skipped + 1)
            )
        # Keep states that have different recent motion. Paths that merge onto
        # the same last two points do not need separate exponential histories.
        unique = {}
        for state in sorted(expanded, key=lambda s: s.cost):
            key = tuple(
                (
                    p.timestamp,
                    round(p.center[0] / max(p.height * 0.35, 1)),
                    round(p.center[1] / max(p.height * 0.35, 1)),
                )
                for p in state.points[-2:]
            )
            if key not in unique:
                unique[key] = state
        states = list(unique.values())[:beam_width]
        if not states:
            break
    finished += states
    # Compare supported path quality, while preferring enough temporal extent to
    # observe a release. Long stationary pre-shot segments bring no extra bonus.
    finished.sort(
        key=lambda s: (
            s.mean_cost - 0.12 * min(2, s.points[0].timestamp - s.points[-1].timestamp),
            -len(s.points),
        )
    )
    result, seen = [], set()
    for state in finished:
        points = list(reversed(state.points))
        key = tuple(
            (
                p.timestamp,
                round(p.center[0] / max(p.height, 1)),
                round(p.center[1] / max(p.height, 1)),
            )
            for p in points
        )
        if key in seen or len(points) < 3:
            continue
        seen.add(key)
        observed = {p.timestamp for p in points}
        missing = [
            t
            for t in times
            if points[0].timestamp <= t <= points[-1].timestamp and t not in observed
        ]
        gaps = []
        supported = True
        if allow_out_of_frame:
            path_frames = {point.timestamp: [point] for point in points}
            for i, (a, b) in enumerate(zip(points, points[1:])):
                if b.timestamp - a.timestamp > max_gap + 1e-6:
                    evidence = top_boundary_bridge(
                        a, points[i + 1 : i + 4], path_frames, frame_size
                    )
                    if evidence is None:
                        supported = False
                        break
                    gaps.append(evidence)
        if not supported:
            continue
        trajectory = BallTrajectory(points, missing, observed_gaps=gaps)
        result.append((trajectory, state.mean_cost))
        if len(result) >= max_paths:
            break
    return result


class JointShooterAttributor:
    def __init__(
        self,
        *,
        min_score=0.78,
        min_margin=0.12,
        min_track_reliability=0.55,
        contextual=False,
        refined=False,
    ):
        self.contextual = contextual
        self.refined = refined
        self.base = ShooterAttributor(
            min_score=min_score,
            min_margin=min_margin,
            min_track_reliability=min_track_reliability,
            release_estimator=ShotReleaseEstimator(
                tolerate_missing_possession=True,
                contextual_possession=contextual,
                refine_release=refined,
            ),
        )

    def attribute(
        self,
        event,
        frames,
        tracks,
        frame_size,
        *,
        tracking_scope,
        sample_fps=15,
        max_gap=0.35,
        min_confidence=0.1,
    ):
        paths = ball_path_hypotheses(
            frames,
            event.timestamp,
            frame_size,
            rim=event.rim,
            max_gap=max_gap,
            min_confidence=min_confidence,
            allow_out_of_frame=self.contextual,
        )
        near_event = any(
            balls and abs(t - event.timestamp) <= max(0.5, max_gap)
            for t, balls in frames
        )
        empty = BallTrajectory(
            reason="ball_event_connection_missing"
            if near_event
            else "ball_missing_at_event"
        )
        result = self.base.attribute(
            event, empty, tracks, tracking_scope=tracking_scope, sample_fps=sample_fps
        )
        result["method"] = (
            "local_release_trajectory_v4"
            if self.refined
            else "contextual_release_trajectory_v3"
            if self.contextual
            else "joint_release_trajectory_v2"
        )
        if not paths:
            return result, empty
        best_cost = paths[0][1]
        hypotheses = []
        for path_index, (trajectory, cost) in enumerate(paths):
            if cost > best_cost + 0.5:
                continue
            estimates = self.base.release_estimator.estimate(
                trajectory, tracks, event.timestamp, sample_fps=sample_fps
            )
            for hypothesis in estimates:
                quality = math.exp(-cost)
                evidence = {
                    **hypothesis.evidence,
                    "trajectory_quality": quality,
                    "trajectory_mean_cost": cost,
                    "path_index": path_index,
                    "path_hypotheses": len(paths),
                }
                if trajectory.observed_gaps:
                    evidence["observed_ball_gaps"] = trajectory.observed_gaps
                hypotheses.append(
                    replace(
                        hypothesis,
                        score=round(0.9 * hypothesis.score + 0.1 * quality, 6),
                        evidence=evidence,
                    )
                )
        best_by_track = {}
        for hypothesis in hypotheses:
            old = best_by_track.get(hypothesis.track_id)
            if old is None or hypothesis.score > old.score:
                best_by_track[hypothesis.track_id] = hypothesis
        ranked = sorted(
            best_by_track.values(), key=lambda h: (-h.score, -h.time, h.track_id)
        )
        result["rankings"] = [h.to_dict() for h in ranked]
        result["trajectory_hypotheses"] = [
            {
                "mean_cost": cost,
                "observations": len(path.observations),
                "missing_samples": len(path.missing_times),
            }
            for path, cost in paths
        ]
        if not ranked:
            result["reason"] = "release_not_observed"
            return result, paths[0][0]
        best = ranked[0]
        trajectory = paths[best.evidence["path_index"]][0]
        reason = None
        if best.evidence["tracking_ambiguous"]:
            reason = "ambiguous_player_tracking"
        elif best.evidence["track_reliability"] < self.base.min_track_reliability:
            reason = "unreliable_player_track"
        elif best.score < self.base.min_score:
            reason = "score_below_threshold"
        elif len(ranked) > 1 and best.score - ranked[1].score < self.base.min_margin:
            reason = "multiple_plausible_shooters"
        elif any(
            h.track_id == best.track_id
            and abs(h.time - best.time) > 0.4
            and abs(h.score - best.score) < 0.06
            for h in hypotheses
        ):
            reason = "release_timing_conflict"
        if reason:
            result["reason"] = reason
        else:
            result.update(
                status="attributed",
                reason="supported_joint_release",
                shooter=best.to_dict(),
            )
        return result, trajectory
