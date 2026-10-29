"""Event-anchored ball reconstruction and scale-aware possession geometry."""

from __future__ import annotations

import math
from dataclasses import dataclass, field

from .player_detection import Detection


def normalized_ball_distance(ball: Detection, player: Detection) -> float:
    """Distance outside the player's box, in player heights (zero inside).

    A held ball may extend beyond the box; the possession radius permits that.
    """
    x, y = ball.center
    x1, y1, x2, y2 = player.bbox
    return math.hypot(max(x1 - x, 0, x - x2), max(y1 - y, 0, y - y2)) / player.height


def possession_strength(ball, player, radius=0.22) -> float:
    distance = normalized_ball_distance(ball, player)
    # Floor-level dribbles do not establish release possession.
    relative_y = (ball.center[1] - player.bbox[1]) / player.height
    if relative_y > 0.7 or relative_y < -0.35:
        return 0.0
    return max(0.0, 1 - distance / radius)


@dataclass
class BallTrajectory:
    observations: list[Detection] = field(default_factory=list)
    missing_times: list[float] = field(default_factory=list)
    ambiguous: bool = False
    reason: str | None = None
    observed_gaps: list[dict] = field(default_factory=list)

    def to_dict(self):
        result = {
            "observations": [d.to_dict() for d in self.observations],
            "missing_times": self.missing_times,
            "ambiguous": self.ambiguous,
            "reason": self.reason,
        }
        if self.observed_gaps:
            result["observed_gaps"] = self.observed_gaps
        return result


def reconstruct_ball_trajectory(
    frames,
    event_time,
    frame_size,
    *,
    rim=None,
    max_gap=0.35,
    min_confidence=0.1,
    max_speed=2.0,
    ambiguity_margin=0.25,
) -> BallTrajectory:
    """Link backward from an observed ball at the event, never inventing points.

    Speed is in frame diagonals/sec. Prediction residuals, ball size changes,
    temporal gaps and alternative branches gate links. A short occlusion remains
    an explicit missing observation; a long gap terminates reconstruction.
    frames is a sequence of (source timestamp, list[Detection]).
    """
    diagonal = math.hypot(*frame_size)
    times = sorted({float(t) for t, _ in frames if t <= event_time + 0.15})
    candidates = {t: [] for t in times}
    for t, detections in frames:
        if t in candidates:
            candidates[t].extend(
                d for d in detections if d.confidence >= min_confidence
            )
    candidates = {
        t: sorted(set(detections), key=lambda d: (-d.confidence, d.bbox))
        for t, detections in candidates.items()
    }
    anchor_times = sorted(
        (t for t in times if candidates[t] and abs(t - event_time) <= max_gap),
        key=lambda t: abs(t - event_time),
    )
    if not anchor_times:
        return BallTrajectory(reason="ball_missing_at_event", missing_times=times)
    anchor_time = anchor_times[0]
    choices = candidates[anchor_time]
    if rim:
        target = (rim["center_x"], rim["rim_y"])
        choices = [
            point
            for point in choices
            if math.dist(point.center, target) <= max(rim["width"] * 3, diagonal * 0.03)
        ]
        if not choices:
            return BallTrajectory(
                reason="ball_not_near_event_anchor", missing_times=times
            )
        anchor_cost = lambda d: (
            math.dist(d.center, target) / rim["width"] + (1 - d.confidence) * 0.5
        )
        choices.sort(key=anchor_cost)
        ambiguous = (
            len(choices) > 1
            and anchor_cost(choices[1]) - anchor_cost(choices[0]) <= ambiguity_margin
        )
    else:
        choices = sorted(choices, key=lambda d: (-d.confidence, d.bbox))
        ambiguous = len(choices) > 1
    chain = [choices[0]]
    for t in reversed([t for t in times if t < anchor_time]):
        last = chain[-1]
        gap = last.timestamp - t
        if gap > max_gap + 1e-6:
            break
        expected = last.center
        if len(chain) > 1:
            next_point = chain[-2]
            dt = next_point.timestamp - last.timestamp
            expected = tuple(
                last.center[i] + (last.center[i] - next_point.center[i]) * gap / dt
                for i in (0, 1)
            )
        ranked = []
        for point in candidates[t]:
            diameter = max(last.height, last.bbox[2] - last.bbox[0], point.height)
            ratio = point.height / last.height
            distance = math.dist(point.center, last.center)
            residual = math.dist(point.center, expected)
            if (
                distance <= diagonal * max_speed * gap + diameter * 2
                and residual <= max(diameter * 4, diagonal * 0.8 * gap)
                and 0.3 <= ratio <= 3.3
            ):
                # Competing hypotheses are compared in ball diameters. A fixed
                # fraction of a 4K frame would incorrectly call nearby hands or
                # duplicate tile detections an equally plausible basketball.
                ranked.append(
                    (residual / diameter + (1 - point.confidence) * 0.5, point)
                )
        ranked.sort(key=lambda pair: (pair[0], pair[1].bbox))
        if ranked:
            if len(ranked) > 1 and ranked[1][0] - ranked[0][0] < ambiguity_margin:
                ambiguous = True
            chain.append(ranked[0][1])
    chain.reverse()
    observed = {d.timestamp for d in chain}
    missing = [
        t
        for t in times
        if chain[0].timestamp <= t <= chain[-1].timestamp and t not in observed
    ]
    return BallTrajectory(
        chain, missing, ambiguous, "ambiguous_ball_path" if ambiguous else None
    )
