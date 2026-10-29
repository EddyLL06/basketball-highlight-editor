"""Validate a top-of-frame ball occlusion using observations on both sides."""

from __future__ import annotations

import math
import statistics


def top_boundary_bridge(earlier, later_points, frames, frame_size):
    """Return explicit gap evidence, never synthetic ball observations.

    At least three observed points on each side must fit a downward-curving
    image-plane arc. Its interior must leave the top of the decoded frame. An
    arbitrary in-frame gap, a lone reappearance or a conflicting path fails.
    The fit is an association check, not a world-coordinate gravity estimate.
    """
    later = sorted(later_points, key=lambda p: p.timestamp)[:3]
    if len(later) < 3:
        return None
    first = later[0]
    gap = first.timestamp - earlier.timestamp
    if not 0 < gap <= 0.85 or later[-1].timestamp - first.timestamp < 0.1:
        return None
    if max(earlier.center[1], first.center[1]) > frame_size[1] * 0.1:
        return None
    import numpy as np

    origin = earlier.timestamp

    def fit(points):
        t = np.array([p.timestamp - origin for p in points])
        matrix = np.column_stack((np.ones_like(t), t, t * t))
        xy = np.array([p.center for p in points])
        coefficients, _, rank, _ = np.linalg.lstsq(matrix, xy, rcond=None)
        if rank < 3:
            return None
        residual = float(np.max(np.linalg.norm(matrix @ coefficients - xy, axis=1)))
        return coefficients, residual

    initial = fit([earlier, *later])
    if initial is None:
        return None
    coefficients, _ = initial
    preceding = []
    for timestamp in sorted(frames, reverse=True):
        if not 0 < earlier.timestamp - timestamp <= 0.22:
            continue
        dt = timestamp - origin
        expected = np.array([1, dt, dt * dt]) @ coefficients
        candidates = frames[timestamp]
        if not candidates:
            continue
        point = min(candidates, key=lambda p: math.dist(p.center, expected))
        if math.dist(point.center, expected) > max(
            4 * point.height, 0.03 * math.hypot(*frame_size)
        ):
            return None
        preceding.append(point)
        if len(preceding) == 2:
            break
    if len(preceding) != 2 or earlier.timestamp - preceding[-1].timestamp < 0.1:
        return None
    observations = [*preceding, earlier, *later]
    fitted = fit(observations)
    if fitted is None:
        return None
    coefficients, residual = fitted
    diameter = statistics.median(
        max(p.height, p.bbox[2] - p.bbox[0]) for p in observations
    )
    if residual > max(2.5 * diameter, 0.0075 * math.hypot(*frame_size)):
        return None
    velocity_before = coefficients[1]
    velocity_after = coefficients[1] + 2 * coefficients[2] * gap
    if (
        coefficients[2, 1] <= 0
        or velocity_before[1] >= 0
        or velocity_after[1] <= 0
        or velocity_before[0] * velocity_after[0] <= 0
    ):
        return None
    outside = 0
    for fraction in (0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9):
        dt = gap * fraction
        x, y = np.array([1, dt, dt * dt]) @ coefficients
        if not 0 <= x <= frame_size[0]:
            return None
        outside += y < -diameter * 0.25
    if outside < 4:
        return None
    return {
        "kind": "top_of_frame_occlusion",
        "start_seconds": earlier.timestamp,
        "end_seconds": first.timestamp,
        "duration_seconds": gap,
        "support_observations": len(observations),
        "max_fit_residual_pixels": residual,
        "synthetic_observations": 0,
    }
