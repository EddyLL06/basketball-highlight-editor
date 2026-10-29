"""Bounded video orchestration for the independent PR1 attribution pipeline."""

from __future__ import annotations

import hashlib
import json
import math
import time
from dataclasses import asdict, dataclass
from pathlib import Path

from .ball_possession import reconstruct_ball_trajectory
from .player_detection import FrameDetector, normalize_detection
from .player_tracking import PlayerTracker
from .sampling import first_frame_index
from .shooter_attribution import SCHEMA_VERSION, ShooterAttributor


@dataclass(frozen=True)
class AnalysisConfig:
    window_before: float = 4.0
    max_window_before: float = 8.0
    window_after: float = 0.15
    sample_fps: float = 12.0
    ball_max_gap: float = 0.35
    ball_min_confidence: float = 0.1
    min_score: float = 0.78
    min_margin: float = 0.12
    min_track_reliability: float = 0.55
    player_max_gap: float = 0.5

    def __post_init__(self):
        if (
            any(not math.isfinite(v) for v in asdict(self).values())
            or not 0 < self.window_before <= self.max_window_before <= 30
            or not 0 <= self.window_after <= 2
            or not 1 <= self.sample_fps <= 120
            or not 0 < self.ball_max_gap <= 1
            or not 0 < self.player_max_gap <= 2
            or any(
                not 0 <= v <= 1
                for v in (
                    self.ball_min_confidence,
                    self.min_score,
                    self.min_margin,
                    self.min_track_reliability,
                )
            )
        ):
            raise ValueError("ATTRIBUTION_CONFIG_INVALID")


@dataclass(frozen=True)
class VideoInfo:
    width: int
    height: int
    fps: float
    frame_count: int

    @property
    def duration(self):
        return self.frame_count / self.fps


def inspect_video(path) -> VideoInfo:
    import cv2

    if not Path(path).is_file():
        raise ValueError(f"VIDEO_NOT_FOUND: {path}")
    cap = cv2.VideoCapture(str(path))
    try:
        if not cap.isOpened():
            raise ValueError("ATTRIBUTION_VIDEO_OPEN_FAILED")
        info = VideoInfo(
            int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)),
            int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)),
            cap.get(cv2.CAP_PROP_FPS),
            int(cap.get(cv2.CAP_PROP_FRAME_COUNT)),
        )
        if (
            min(info.width, info.height, info.frame_count) <= 0
            or not math.isfinite(info.fps)
            or info.fps <= 0
        ):
            raise ValueError("ATTRIBUTION_VIDEO_METADATA_INVALID")
        return info
    finally:
        cap.release()


def iter_video_frames(path, start, end, sample_fps, info):
    """Decode one bounded range on a global grid; yield actual source PTS.

    Frame indices select samples without accumulated rounding drift. OpenCV's
    presentation timestamp is retained where available (including VFR); nominal
    frame time is a documented fallback for backends without PTS support.
    """
    import cv2

    cap = cv2.VideoCapture(str(path))
    try:
        if not cap.isOpened():
            raise ValueError("ATTRIBUTION_VIDEO_OPEN_FAILED")
        rate = min(sample_fps, info.fps)
        first_tick = math.ceil(start * rate - 1e-9)
        last_tick = math.ceil(end * rate - 1e-9)
        indices = sorted(
            {
                min(info.frame_count - 1, first_frame_index(t / rate, info.fps))
                for t in range(first_tick, last_tick)
            }
        )
        if not indices:
            return
        frame_index = indices[0]
        if not cap.set(cv2.CAP_PROP_POS_FRAMES, frame_index):
            raise ValueError("ATTRIBUTION_VIDEO_SEEK_FAILED")
        # Backends may seek to an earlier keyframe; respect the reported index.
        frame_index = int(cap.get(cv2.CAP_PROP_POS_FRAMES))
        previous_time = -1.0
        for target in indices:
            while frame_index <= target:
                if not cap.grab():
                    return
                if frame_index == target:
                    ok, frame = cap.retrieve()
                    if not ok:
                        return
                    pts = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000
                    use_pts = (
                        math.isfinite(pts)
                        and pts > previous_time
                        and (pts > 0 or target == 0)
                    )
                    timestamp = pts if use_pts else target / info.fps
                    previous_time = timestamp
                    if start - 1 / info.fps <= timestamp < end + 1 / info.fps:
                        yield target, timestamp, frame
                frame_index += 1
    finally:
        cap.release()


def merge_event_windows(events, config, duration):
    windows = []
    for event in sorted(events, key=lambda e: e.timestamp):
        start = max(0.0, event.timestamp - config.window_before)
        end = min(duration, event.timestamp + config.window_after)
        if event.timestamp >= duration or end <= start:
            raise ValueError(f"ATTRIBUTION_EVENT_OUTSIDE_VIDEO: {event.candidate_id}")
        if windows and start <= windows[-1]["end"]:
            windows[-1]["end"] = max(windows[-1]["end"], end)
            windows[-1]["events"].append(event)
        else:
            windows.append({"start": start, "end": end, "events": [event]})
    return windows


def load_ball_records(payload, *, video=None, scale=None, time_offset=0.0):
    """Read BHE detection logs. Cropped scan xyxy is already crop-transformed.

    A different input video (e.g. a proxy) requires an explicit source-pixel
    scale. Arbitrary ROI/net-motion caches are not accepted as full-frame data.
    """
    if not isinstance(payload, dict) or not isinstance(payload.get("records"), list):
        raise ValueError("ATTRIBUTION_BALL_RECORDS_INVALID")
    if video and scale is None:
        source = payload.get("video")
        if not source or Path(source).resolve() != Path(video).resolve():
            raise ValueError("ATTRIBUTION_RECORDS_REQUIRE_EXPLICIT_SCALE")
    scale = 1.0 if scale is None else scale
    records = []
    for record in payload["records"]:
        timestamp = float(record["time"]) + time_offset
        if not math.isfinite(timestamp) or timestamp < 0:
            raise ValueError("ATTRIBUTION_RECORD_TIMESTAMP_INVALID")
        balls = []
        for detection in record.get("detections", []):
            if detection.get("name") != "ball":
                continue
            try:
                balls.append(
                    normalize_detection(
                        timestamp,
                        detection["xyxy"],
                        detection["confidence"],
                        scale=(scale, scale),
                    )
                )
            except (KeyError, TypeError, ValueError):
                continue
        records.append((timestamp, balls))
    return records


class ShooterAttributionPipeline:
    def __init__(
        self,
        player_detector: FrameDetector,
        ball_detector: FrameDetector | None,
        *,
        config=None,
        video_reader=iter_video_frames,
        video_inspector=inspect_video,
        algorithm="joint",
        use_appearance=True,
    ):
        self.player_detector, self.ball_detector = player_detector, ball_detector
        self.config = config or AnalysisConfig()
        self.reader, self.inspector = video_reader, video_inspector
        if algorithm not in ("baseline", "joint", "joint-v3", "joint-v4"):
            raise ValueError("ATTRIBUTION_ALGORITHM_INVALID")
        self.algorithm = algorithm
        self.use_appearance = use_appearance

    def analyze(
        self, video, events, *, ball_records=(), progress=None, observation_archive=None
    ):
        started = time.perf_counter()
        info = self.inspector(video)
        cfg = self.config
        groups = merge_event_windows(events, cfg, info.duration)
        if self.algorithm != "baseline":
            from .joint_attribution import JointShooterAttributor

            factory = JointShooterAttributor
        else:
            factory = ShooterAttributor
        attributor = factory(
            min_score=cfg.min_score,
            min_margin=cfg.min_margin,
            min_track_reliability=cfg.min_track_reliability,
            **(
                {"contextual": True, "refined": self.algorithm == "joint-v4"}
                if self.algorithm in ("joint-v3", "joint-v4")
                else {}
            ),
        )
        # Only compact observations are memoized, never whole video frames.
        memo = {}
        sessions, by_id = [], {}
        inference_seconds = 0.0
        reused_ball_frames = 0
        video_path = Path(video)
        stat = video_path.stat() if video_path.is_file() else None
        fingerprint = {
            "name": video_path.name,
            "size": stat.st_size if stat else None,
            "mtime_ns": stat.st_mtime_ns if stat else None,
        }
        for group_index, group in enumerate(groups):
            group_started = time.perf_counter()
            start, end = group["start"], group["end"]
            expanded = False
            while True:
                source = (
                    observation_archive.window(
                        start, end, min(cfg.sample_fps, info.fps)
                    )
                    if observation_archive is not None
                    else self.reader(video, start, end, cfg.sample_fps, info)
                )
                for record in source:
                    frame_index, timestamp = record[:2]
                    if frame_index in memo:
                        continue
                    if observation_archive is not None:
                        memo[frame_index] = (timestamp, record[2], record[3])
                        continue
                    frame = record[2]
                    tick = time.perf_counter()
                    players = self.player_detector.detect(frame, timestamp)
                    # Native/cropped cache observations retain their own timestamps;
                    # use inference if no sufficiently aligned cached ball exists.
                    nearest = min(
                        ball_records,
                        key=lambda row: abs(row[0] - timestamp),
                        default=None,
                    )
                    aligned = (
                        nearest is not None
                        and abs(nearest[0] - timestamp)
                        < 0.5 / min(cfg.sample_fps, info.fps)
                        and nearest[1]
                    )
                    if aligned:
                        reused_ball_frames += 1
                        balls = nearest[1]
                    else:
                        balls = (
                            self.ball_detector.detect_with_players(
                                frame, timestamp, players
                            )
                            if hasattr(self.ball_detector, "detect_with_players")
                            else self.ball_detector.detect(frame, timestamp)
                            if self.ball_detector
                            else []
                        )
                    memo[frame_index] = (timestamp, players, balls)
                    inference_seconds += time.perf_counter() - tick
                observations = sorted(
                    (value for value in memo.values() if start <= value[0] <= end),
                    key=lambda v: v[0],
                )
                tracker = PlayerTracker(
                    max_gap_seconds=cfg.player_max_gap,
                    global_assignment=self.algorithm != "baseline",
                    use_appearance=self.algorithm != "baseline" and self.use_appearance,
                    suppress_duplicates=self.algorithm in ("joint-v3", "joint-v4"),
                )
                for timestamp, players, _ in observations:
                    tracker.update(timestamp, players)
                # Track IDs can change with weights/detection thresholds even if
                # time windows do not. Bind labels to the actual track histories.
                scope_key = json.dumps(
                    [
                        fingerprint,
                        {
                            "algorithm": self.algorithm,
                            "appearance": self.use_appearance,
                        },
                        asdict(cfg),
                        start,
                        end,
                        [track.to_dict() for track in tracker.tracks],
                    ],
                    sort_keys=True,
                )
                scope = "session_" + hashlib.sha256(scope_key.encode()).hexdigest()[:20]
                results = []
                for event in group["events"]:
                    lower = max(
                        start,
                        event.timestamp
                        - (cfg.max_window_before if expanded else cfg.window_before),
                    )
                    # Cached ball observations keep their actual timestamps;
                    # person boxes are associated with a bounded time tolerance.
                    relevant = [
                        (t, [])
                        for t, _, _ in observations
                        if lower <= t <= event.timestamp + cfg.window_after
                    ]
                    relevant += [
                        (d.timestamp, [d])
                        for _, _, balls in observations
                        for d in balls
                        if lower <= d.timestamp <= event.timestamp + cfg.window_after
                    ]
                    if self.algorithm != "baseline":
                        result, trajectory = attributor.attribute(
                            event,
                            relevant,
                            tracker.tracks,
                            (info.width, info.height),
                            tracking_scope=scope,
                            sample_fps=min(cfg.sample_fps, info.fps),
                            max_gap=cfg.ball_max_gap,
                            min_confidence=cfg.ball_min_confidence,
                        )
                    else:
                        trajectory = reconstruct_ball_trajectory(
                            relevant,
                            event.timestamp,
                            (info.width, info.height),
                            rim=event.rim,
                            max_gap=cfg.ball_max_gap,
                            min_confidence=cfg.ball_min_confidence,
                        )
                        result = attributor.attribute(
                            event,
                            trajectory,
                            tracker.tracks,
                            tracking_scope=scope,
                            sample_fps=min(cfg.sample_fps, info.fps),
                        )
                    result["analysis_window_ms"] = [
                        round(lower * 1000),
                        round(min(end, event.timestamp + cfg.window_after) * 1000),
                    ]
                    result["ball_trajectory"] = trajectory.to_dict()
                    results.append(result)
                needs_expansion = any(
                    r["reason"] == "release_not_observed" for r in results
                )
                expanded_start = max(
                    0.0,
                    min(e.timestamp for e in group["events"]) - cfg.max_window_before,
                )
                if not expanded and needs_expansion and expanded_start < start:
                    start, expanded = expanded_start, True
                    continue
                break
            group_elapsed = time.perf_counter() - group_started
            for result in results:
                result["processing_seconds"] = group_elapsed / len(results)
                result["window_expanded"] = expanded
                by_id[result["candidate_id"]] = result
            sessions.append(
                {
                    "tracking_scope": scope,
                    "start_ms": round(start * 1000),
                    "end_ms": round(end * 1000),
                    "tracks": [track.to_dict() for track in tracker.tracks],
                }
            )
            if progress:
                progress((group_index + 1) / len(groups))
        return {
            "schema_version": SCHEMA_VERSION,
            "video": video_path.name,
            "video_fingerprint": fingerprint,
            "coordinate_system": "source_decoded_pixels_xyxy",
            "timestamp_unit": "source_seconds",
            "frame_width": info.width,
            "frame_height": info.height,
            "video_fps": info.fps,
            "config": asdict(cfg),
            "results": [by_id[event.candidate_id] for event in events],
            "sessions": sessions,
            "performance": {
                "elapsed_seconds": time.perf_counter() - started,
                "detector_seconds": inference_seconds,
                "replayed_observations": observation_archive is not None,
                "unique_sampled_frames": len(memo),
                "reused_ball_frames": reused_ball_frames,
                "tracking_sessions": len(sessions),
                "candidate_timing": "shared session wall time divided by session candidates",
            },
        }
