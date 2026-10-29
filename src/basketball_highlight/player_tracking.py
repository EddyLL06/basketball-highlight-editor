"""Short-session global matching with optional local clothing-color evidence.

High-confidence matching followed by low-confidence rescue is inspired by
ByteTrack. This is an independent conservative baseline, not a ByteTrack port.
Ambiguous associations are exposed so downstream attribution can abstain.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

from .player_detection import Detection


def bbox_iou(a, b) -> float:
    intersection = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(
        0, min(a[3], b[3]) - max(a[1], b[1])
    )
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - intersection
    return intersection / union if union > 0 else 0.0


@dataclass
class PlayerTrack:
    track_id: int
    observations: list[Detection] = field(default_factory=list)
    ambiguous_times: list[float] = field(default_factory=list)
    appearance_profile: tuple[float, ...] | None = None

    def at(self, timestamp: float, tolerance: float = 0.12) -> Detection | None:
        if not self.observations:
            return None
        observation = min(self.observations, key=lambda d: abs(d.timestamp - timestamp))
        return (
            observation
            if abs(observation.timestamp - timestamp) <= tolerance + 1e-6
            else None
        )

    def reliability(self, start, end, sample_fps) -> float:
        observations = [d for d in self.observations if start <= d.timestamp <= end]
        if not observations:
            return 0.0
        coverage = min(1.0, len(observations) / max(1.0, (end - start) * sample_fps))
        return coverage * sum(d.confidence for d in observations) / len(observations)

    def predicted_bbox(self, timestamp):
        last = self.observations[-1]
        if len(self.observations) < 2:
            return last.bbox
        previous = self.observations[-2]
        dt = last.timestamp - previous.timestamp
        if dt <= 0:
            return last.bbox
        factor = min((timestamp - last.timestamp) / dt, 3.0)
        dx = (last.center[0] - previous.center[0]) * factor
        dy = (last.center[1] - previous.center[1]) * factor
        return tuple(v + (dx if i % 2 == 0 else dy) for i, v in enumerate(last.bbox))

    def to_dict(self):
        return {
            "track_id": self.track_id,
            "observations": [d.to_dict() for d in self.observations],
            "ambiguous_times": self.ambiguous_times,
        }


def minimum_cost_assignment(costs):
    """Rectangular minimum-cost assignment using primal/dual augmenting paths.

    Pure Python, O(n^3), deterministic ties. Dummy columns can model unmatched
    tracks. No SciPy/LAP wheel or implicit package installation is required.
    """
    if not costs or not costs[0]:
        return []
    n, m = len(costs), len(costs[0])
    if any(len(row) != m or any(not math.isfinite(v) for v in row) for row in costs):
        raise ValueError("ATTRIBUTION_ASSIGNMENT_COSTS_INVALID")
    if n > m:
        return sorted(
            (j, i)
            for i, j in minimum_cost_assignment([list(row) for row in zip(*costs)])
        )
    u, v, p, way = [0.0] * (n + 1), [0.0] * (m + 1), [0] * (m + 1), [0] * (m + 1)
    for row in range(1, n + 1):
        p[0], j0 = row, 0
        minimum, used = [math.inf] * (m + 1), [False] * (m + 1)
        while True:
            used[j0] = True
            i0, delta, j1 = p[j0], math.inf, 0
            for j in range(1, m + 1):
                if not used[j]:
                    reduced = costs[i0 - 1][j - 1] - u[i0] - v[j]
                    if reduced < minimum[j]:
                        minimum[j], way[j] = reduced, j0
                    if minimum[j] < delta:
                        delta, j1 = minimum[j], j
            for j in range(m + 1):
                if used[j]:
                    u[p[j]] += delta
                    v[j] -= delta
                else:
                    minimum[j] -= delta
            j0 = j1
            if p[j0] == 0:
                break
        while j0:
            j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
    return sorted((p[j] - 1, j - 1) for j in range(1, m + 1) if p[j])


def appearance_distance(a, b):
    if a is None or b is None or len(a) != len(b):
        return None
    return math.sqrt(max(0.0, 1 - sum(math.sqrt(x * y) for x, y in zip(a, b))))


def suppress_player_duplicates(detections):
    """Remove near-identical boxes only when their torso evidence also agrees.

    Ordinary overlap between differently dressed players must survive. Without
    appearance, only essentially identical boxes are considered duplicates.
    """
    kept = []
    for detection in sorted(detections, key=lambda d: (-d.confidence, d.bbox)):
        duplicate = False
        for other in kept:
            overlap = bbox_iou(detection.bbox, other.bbox)
            a, b = detection.bbox, other.bbox
            intersection = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(
                0, min(a[3], b[3]) - max(a[1], b[1])
            )
            containment = intersection / min(
                (a[2] - a[0]) * (a[3] - a[1]),
                (b[2] - b[0]) * (b[3] - b[1]),
            )
            visual = appearance_distance(detection.appearance, other.appearance)
            if (
                overlap >= 0.65
                and containment >= 0.9
                and visual is not None
                and visual <= 0.35
            ) or (overlap >= 0.9 and visual is None):
                duplicate = True
                break
        if not duplicate:
            kept.append(detection)
    return kept


class PlayerTracker:
    def __init__(
        self,
        *,
        max_gap_seconds=0.5,
        high_threshold=0.45,
        low_threshold=0.15,
        ambiguity_margin=0.12,
        global_assignment=True,
        use_appearance=True,
        suppress_duplicates=False,
    ):
        if (
            not math.isfinite(max_gap_seconds)
            or max_gap_seconds <= 0
            or not 0 <= low_threshold <= high_threshold <= 1
            or not 0 <= ambiguity_margin < 1
        ):
            raise ValueError("ATTRIBUTION_TRACKER_PARAMETERS_INVALID")
        self.max_gap = max_gap_seconds
        self.high, self.low, self.margin = (
            high_threshold,
            low_threshold,
            ambiguity_margin,
        )
        self.tracks: list[PlayerTrack] = []
        self.last_timestamp = -1.0
        self.global_assignment, self.use_appearance = global_assignment, use_appearance
        self.suppress_duplicates = suppress_duplicates

    def update(self, timestamp: float, detections: list[Detection]):
        if not math.isfinite(timestamp) or timestamp <= self.last_timestamp:
            raise ValueError("ATTRIBUTION_TRACKER_TIME_NOT_INCREASING")
        if any(abs(d.timestamp - timestamp) > 1e-6 for d in detections):
            raise ValueError("ATTRIBUTION_TRACKER_TIME_MISMATCH")
        self.last_timestamp = timestamp
        if self.suppress_duplicates:
            detections = suppress_player_duplicates(detections)
        active = [
            t
            for t in self.tracks
            if timestamp - t.observations[-1].timestamp <= self.max_gap
        ]
        unmatched = {t.track_id: t for t in active}
        remaining = sorted(
            (d for d in detections if d.confidence >= self.low),
            key=lambda d: (-d.confidence, d.bbox),
        )
        for high_pass in (True, False):
            pool = [d for d in remaining if (d.confidence >= self.high) == high_pass]
            edges = []
            for track in unmatched.values():
                predicted = track.predicted_bbox(timestamp)
                center = (
                    (predicted[0] + predicted[2]) / 2,
                    (predicted[1] + predicted[3]) / 2,
                )
                for i, detection in enumerate(pool):
                    distance = math.dist(center, detection.center) / max(
                        track.observations[-1].height, detection.height
                    )
                    overlap = bbox_iou(predicted, detection.bbox)
                    ratio = detection.height / track.observations[-1].height
                    visual = (
                        appearance_distance(
                            track.appearance_profile, detection.appearance
                        )
                        if self.use_appearance
                        else None
                    )
                    if (
                        distance <= 0.8
                        and 0.5 <= ratio <= 2.0
                        and (
                            overlap >= 0.05
                            or distance < 0.35
                            or (visual is not None and visual < 0.25)
                        )
                    ):
                        geometry = 0.65 * (1 - overlap) + 0.35 * distance
                        if visual is not None and visual > 0.85:
                            continue
                        cost = (
                            geometry
                            if visual is None
                            else 0.55 * geometry + 0.45 * visual
                        )
                        edges.append((cost, track.track_id, i))
            used = set()
            ambiguous_ids = set()
            assignments = sorted(edges)
            if self.global_assignment and unmatched and pool:
                tracks = list(unmatched.values())
                matrix = [[1e4] * len(pool) + [0.9] * len(tracks) for _ in tracks]
                row_for = {t.track_id: row for row, t in enumerate(tracks)}
                for cost, track_id, i in edges:
                    matrix[row_for[track_id]][i] = cost
                optimal = minimum_cost_assignment(matrix)
                total = sum(matrix[row][col] for row, col in optimal)
                assignments = [
                    (matrix[row][col], tracks[row].track_id, col)
                    for row, col in optimal
                    if col < len(pool) and matrix[row][col] < 0.9
                ]
                for row, col in optimal:
                    if col >= len(pool) or matrix[row][col] >= 0.9:
                        continue
                    alternate = [list(values) for values in matrix]
                    alternate[row][col] = 1e4
                    other = minimum_cost_assignment(alternate)
                    if sum(alternate[a][b] for a, b in other) - total < self.margin:
                        selected = dict(optimal)
                        ambiguous_ids.update(
                            tracks[a].track_id for a, b in other if b != selected[a]
                        )
            for cost, track_id, i in assignments:
                if track_id not in unmatched or i in used:
                    continue
                track = unmatched.pop(track_id)
                alternatives = [
                    (c, tid, j)
                    for c, tid, j in edges
                    if (tid == track_id and j != i) or (j == i and tid != track_id)
                ]
                ambiguous = (
                    track_id in ambiguous_ids
                    if self.global_assignment
                    else any(abs(c - cost) < self.margin for c, _, _ in alternatives)
                )
                if ambiguous:
                    track.ambiguous_times.append(timestamp)
                    for c, tid, _ in alternatives:
                        if abs(c - cost) < self.margin and tid in unmatched:
                            unmatched[tid].ambiguous_times.append(timestamp)
                detection = pool[i]
                track.observations.append(detection)
                crowded = any(
                    other is not detection
                    and bbox_iou(detection.bbox, other.bbox) > 0.25
                    for other in detections
                )
                if (
                    self.use_appearance
                    and not ambiguous
                    and not crowded
                    and detection.confidence >= self.high
                    and detection.appearance is not None
                ):
                    if track.appearance_profile is None:
                        track.appearance_profile = detection.appearance
                    else:
                        track.appearance_profile = tuple(
                            0.9 * a + 0.1 * b
                            for a, b in zip(
                                track.appearance_profile, detection.appearance
                            )
                        )
                used.add(i)
                remaining.remove(pool[i])
        for detection in remaining:
            if detection.confidence >= self.high:
                crowded = any(
                    other is not detection
                    and bbox_iou(detection.bbox, other.bbox) > 0.25
                    for other in detections
                )
                self.tracks.append(
                    PlayerTrack(
                        len(self.tracks) + 1,
                        [detection],
                        appearance_profile=detection.appearance
                        if self.use_appearance and not crowded
                        else None,
                    )
                )
        return self.tracks
