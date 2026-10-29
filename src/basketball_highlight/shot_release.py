"""Explainable release intervals from possession followed by sustained separation."""

from __future__ import annotations

import math
import statistics
from dataclasses import dataclass

from .ball_possession import normalized_ball_distance, possession_strength


@dataclass(frozen=True)
class ReleaseEstimate:
    track_id: int
    time: float
    interval: tuple[float, float]
    position: tuple[float, float]
    score: float
    evidence: dict

    def to_dict(self):
        return {
            "track_id": self.track_id,
            "release_time_ms": round(self.time * 1000),
            "release_interval_ms": [round(t * 1000) for t in self.interval],
            "release_position": list(self.position),
            "score": self.score,
            "score_kind": "heuristic",
            "evidence": self.evidence,
        }


class ShotReleaseEstimator:
    def __init__(
        self,
        *,
        possession_radius=0.22,
        possession_window=0.45,
        min_possession_observations=2,
        separation=0.25,
        flight_window=0.45,
        max_observation_gap=0.25,
        min_flight_observations=3,
        tolerate_missing_possession=False,
        contextual_possession=False,
        refine_release=False,
    ):
        values = (
            possession_radius,
            possession_window,
            separation,
            flight_window,
            max_observation_gap,
        )
        if (
            any(not math.isfinite(v) or v <= 0 for v in values)
            or min_possession_observations < 2
            or min_flight_observations < 2
        ):
            raise ValueError("ATTRIBUTION_RELEASE_PARAMETERS_INVALID")
        self.radius, self.lookback = possession_radius, possession_window
        self.minimum, self.separation = min_possession_observations, separation
        self.flight_window, self.max_gap = flight_window, max_observation_gap
        self.min_flight = min_flight_observations
        self.tolerate_missing_possession = tolerate_missing_possession
        self.contextual_possession = contextual_possession
        if refine_release and not contextual_possession:
            raise ValueError("ATTRIBUTION_REFINEMENT_REQUIRES_CONTEXT")
        if refine_release and min_flight_observations < 3:
            raise ValueError("ATTRIBUTION_REFINEMENT_REQUIRES_THREE_FLIGHT_POINTS")
        self.refine_release = refine_release

    def estimate(self, ball_track, player_tracks, scoring_time, *, sample_fps=12):
        """Return ranked release hypotheses, preserving sample-time uncertainty.

        A hypothesis needs multiple held-ball observations, upper-body release
        geometry, relative motion away from the player and sustained separation
        on the ball path that reaches the scoring event. Upward motion alone is
        deliberately insufficient. A subsequent catch/possession vetoes a pass.
        """
        points = ball_track.observations
        if len(points) < self.minimum + self.min_flight or ball_track.ambiguous:
            return []
        tolerance = min(self.max_gap, 0.55 / sample_fps)
        estimates = []
        for track in player_tracks:
            hypotheses = []
            for i in range(self.minimum - 1, len(points) - self.min_flight):
                held = points[i]
                flight = points[i + 1 :]
                if (
                    scoring_time - held.timestamp < 0.18
                    or scoring_time - held.timestamp > 6
                ):
                    continue
                player = track.at(held.timestamp, tolerance)
                if (
                    player is None
                    or possession_strength(held, player, self.radius) <= 0
                ):
                    continue
                # Use the end of the final contiguous possession run, never an
                # arbitrary earlier sample while the ball remains in hand.
                first_player = track.at(flight[0].timestamp, tolerance)
                if (
                    first_player is None
                    or possession_strength(flight[0], first_player, self.radius) > 0
                ):
                    continue
                history = []
                missing_possession = 0
                for point in reversed(points[: i + 1]):
                    if held.timestamp - point.timestamp > self.lookback:
                        break
                    previous_player = track.at(point.timestamp, tolerance)
                    if (
                        previous_player is None
                        or possession_strength(point, previous_player, self.radius) <= 0
                    ):
                        missing_possession += 1
                        if self.tolerate_missing_possession and missing_possession <= 1:
                            continue
                        break
                    if (
                        history
                        and history[-1].timestamp - point.timestamp > self.max_gap
                    ):
                        break
                    history.append(point)
                if (
                    len(history) < self.minimum
                    or history[0].timestamp - history[-1].timestamp < 0.06
                ):
                    continue
                if flight[0].timestamp - held.timestamp > self.max_gap:
                    continue
                # A broad body-box radius can also cover a nearby defender.
                # Reject that explanation when the same observed ball was
                # consistently much closer to another player's upper body.
                ownership = []
                if self.contextual_possession:
                    own = [
                        possession_strength(
                            p, track.at(p.timestamp, tolerance), self.radius
                        )
                        for p in history
                    ]
                    dominated = False
                    for other in player_tracks:
                        if other.track_id == track.track_id:
                            continue
                        rival = [
                            possession_strength(p, observation, self.radius)
                            if (observation := other.at(p.timestamp, tolerance))
                            else 0
                            for p in history
                        ]
                        ownership.append(rival)
                        if (
                            sum(rival) / len(rival) >= 0.65
                            and sum(b - a for a, b in zip(own, rival)) / len(own) >= 0.2
                        ):
                            dominated = True
                            break
                    if dominated:
                        continue
                relative_y = (held.center[1] - player.bbox[1]) / player.height
                if relative_y > 0.45 and not self.refine_release:
                    continue
                post = [
                    point
                    for point in flight
                    if point.timestamp - held.timestamp <= self.flight_window + 1e-6
                ]
                if len(post) < self.min_flight:
                    continue
                original_post_end = post[-1].timestamp
                if self.refine_release:
                    later_ambiguities = [
                        t
                        for t in track.ambiguous_times
                        if post[2].timestamp < t <= original_post_end
                    ]
                    if later_ambiguities:
                        post = [p for p in post if p.timestamp < min(later_ambiguities)]
                ownership_margin = (
                    sum(
                        a - max((r[j] for r in ownership), default=0)
                        for j, a in enumerate(own)
                    )
                    / len(own)
                    if self.contextual_possession
                    else 0
                )
                underhand = False
                if self.refine_release and relative_y > 0.45:
                    ascent = (held.center[1] - post[2].center[1]) / player.height
                    underhand = (
                        relative_y <= 0.65
                        and ascent >= 0.15
                        and len(history) >= 3
                        and ownership_margin >= 0.2
                        and all(
                            b.center[1] < a.center[1]
                            for a, b in zip([held, *post[:2]], post[:3])
                        )
                    )
                    if not underhand:
                        continue
                distances = []
                for point in post:
                    observation = track.at(point.timestamp, tolerance)
                    if observation is None:
                        break
                    distances.append(normalized_ball_distance(point, observation))
                if len(distances) < self.min_flight:
                    continue
                separation_gain = distances[-1] - normalized_ball_distance(held, player)
                if (
                    distances[-1] < self.separation
                    or separation_gain < self.separation * 0.8
                ):
                    continue
                if (
                    sum(b >= a - 0.04 for a, b in zip(distances, distances[1:]))
                    < len(distances) - 2
                ):
                    continue
                displacement = (
                    max(math.dist(point.center, held.center) for point in post)
                    if self.contextual_possession
                    else math.dist(post[-1].center, held.center)
                ) / player.height
                compact_release = (
                    self.refine_release
                    and len(history) >= 3
                    and ownership_margin >= 0.25
                    and separation_gain >= 0.4
                    and displacement
                    >= max(
                        0.1,
                        1.5
                        * statistics.median(
                            max(p.height, p.bbox[2] - p.bbox[0]) for p in [held, *post]
                        )
                        / player.height,
                    )
                )
                if displacement < self.separation and not compact_release:
                    continue
                # More than one later upper-body possession sample indicates a
                # pass, catch, rebound or putback. The final release is evaluated
                # separately rather than crediting the earlier passer.
                later_possession = False
                for other in player_tracks:
                    run = 0
                    previous_relative = None
                    possession_start = None
                    for point in flight:
                        if (
                            point.timestamp
                            <= (
                                held.timestamp + 0.1
                                if self.contextual_possession
                                else post[-1].timestamp
                            )
                            or scoring_time - point.timestamp < 0.15
                        ):
                            continue
                        observation = other.at(point.timestamp, tolerance)
                        relative = (
                            tuple(
                                (point.center[k] - observation.center[k])
                                / observation.height
                                for k in (0, 1)
                            )
                            if observation is not None
                            else None
                        )
                        fast_flight = (
                            self.tolerate_missing_possession
                            and relative is not None
                            and previous_relative is not None
                            and math.dist(relative, previous_relative[1])
                            / (point.timestamp - previous_relative[0])
                            > 1.5
                        )
                        run = (
                            run + 1
                            if observation
                            and possession_strength(point, observation, self.radius) > 0
                            and not fast_flight
                            else 0
                        )
                        if run == 1:
                            possession_start = point.timestamp
                        previous_relative = (
                            (point.timestamp, relative)
                            if relative is not None
                            else None
                        )
                        if run >= self.minimum and (
                            not self.tolerate_missing_possession
                            or point.timestamp - possession_start >= 0.1
                        ):
                            later_possession = True
                            break
                    if later_possession:
                        break
                if later_possession:
                    continue
                reliability = track.reliability(
                    history[-1].timestamp, post[-1].timestamp, sample_fps
                )
                ambiguous = any(
                    history[-1].timestamp
                    - (0 if self.contextual_possession else self.max_gap)
                    <= t
                    <= original_post_end
                    for t in track.ambiguous_times
                )
                history_ambiguous = ambiguous
                if self.refine_release and ambiguous and ownership_margin >= 0.25:
                    # The visible releaser needs a stable identity across the
                    # release, not a globally stable ID throughout the clip.
                    ambiguous = any(
                        history[1].timestamp <= t <= post[2].timestamp
                        for t in track.ambiguous_times
                    )
                detection_score = sum(p.confidence for p in history + post) / len(
                    history + post
                )
                # Explainable ranking score, explicitly not a probability.
                features = {
                    "possession_observations": len(history),
                    "possession_duration_seconds": held.timestamp
                    - history[-1].timestamp,
                    "possession_consistency": min(1.0, len(history) / 3),
                    "proximity": sum(
                        possession_strength(
                            p, track.at(p.timestamp, tolerance), self.radius
                        )
                        for p in history
                    )
                    / len(history),
                    "separation": min(1.0, separation_gain / 0.6),
                    "track_reliability": reliability,
                    "ball_detection_score": detection_score,
                    "flight_observations": len(flight),
                    "release_height_ratio": relative_y,
                    "tracking_ambiguous": ambiguous,
                }
                if self.contextual_possession:
                    features["possession_ownership_margin"] = ownership_margin
                if self.refine_release:
                    features.update(
                        tracking_history_ambiguous=history_ambiguous,
                        release_identity_revalidated=history_ambiguous
                        and not ambiguous,
                        compact_release=compact_release
                        and displacement < self.separation,
                        upward_underhand_release=underhand,
                        flight_displacement_player_heights=displacement,
                        flight_evidence_end_seconds=post[-1].timestamp,
                    )
                score = (
                    0.25 * features["possession_consistency"]
                    + 0.2 * features["proximity"]
                    + 0.2 * features["separation"]
                    + 0.2 * reliability
                    + 0.15 * detection_score
                )
                hypotheses.append(
                    ReleaseEstimate(
                        track.track_id,
                        (held.timestamp + flight[0].timestamp) / 2,
                        (held.timestamp, flight[0].timestamp),
                        held.center,
                        round(score, 6),
                        features,
                    )
                )
            if hypotheses:
                estimates.append(max(hypotheses, key=lambda h: h.time))
        return sorted(estimates, key=lambda h: (-h.score, -h.time, h.track_id))
