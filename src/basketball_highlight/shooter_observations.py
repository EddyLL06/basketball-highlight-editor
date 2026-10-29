"""Versioned local observation replay; model inference and algorithm evaluation separate."""

from __future__ import annotations

import hashlib
import json
import math
import time
from dataclasses import asdict, replace
from pathlib import Path

from .player_detection import Detection


def video_fingerprint(video):
    path = Path(video)
    stat = path.stat()
    return {"name": path.name, "size": stat.st_size, "mtime_ns": stat.st_mtime_ns}


def model_fingerprint(path):
    path = Path(path)
    return {"name": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def write_artifact(path, payload):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, allow_nan=False), encoding="utf-8"
    )
    temporary.replace(path)


class ObservationArchive:
    def __init__(self, payload, video):
        if payload.get("schema_version") != 1 or payload.get(
            "video_fingerprint"
        ) != video_fingerprint(video):
            raise ValueError("ATTRIBUTION_OBSERVATION_SOURCE_MISMATCH")
        self.payload = payload
        self.sample_fps = float(payload["sample_fps"])
        if not math.isfinite(self.sample_fps) or self.sample_fps <= 0:
            raise ValueError("ATTRIBUTION_OBSERVATION_RATE_INVALID")
        self.frames = []
        previous_frame, previous_time = -1, -1.0
        for record in payload["frames"]:
            index, timestamp = record["frame_index"], float(record["timestamp"])
            if (
                index <= previous_frame
                or timestamp <= previous_time
                or not math.isfinite(timestamp)
            ):
                raise ValueError("ATTRIBUTION_OBSERVATION_ORDER_INVALID")
            players = [Detection.from_dict(d) for d in record["players"]]
            balls = [Detection.from_dict(d) for d in record["balls"]]
            if any(abs(d.timestamp - timestamp) > 1e-6 for d in players + balls):
                raise ValueError("ATTRIBUTION_OBSERVATION_TIME_MISMATCH")
            self.frames.append((index, timestamp, players, balls))
            previous_frame, previous_time = index, timestamp

    def window(self, start, end, sample_fps):
        if abs(sample_fps - self.sample_fps) > 1e-6:
            raise ValueError("ATTRIBUTION_OBSERVATION_RATE_MISMATCH")
        if not any(
            a <= start + 0.001 and b >= end - 0.001 for a, b in self.payload["windows"]
        ):
            raise ValueError("ATTRIBUTION_OBSERVATION_WINDOW_NOT_RECORDED")
        return [
            (i, t, players, balls)
            for i, t, players, balls in self.frames
            if start <= t < end
        ]


def collect_observations(
    video, events, player_detector, ball_detector, config, *, models=None, progress=None
):
    from .attribution_video import inspect_video, iter_video_frames, merge_event_windows

    started = time.perf_counter()
    info = inspect_video(video)
    # Record the expansion window once, so all algorithm variants replay exactly
    # the same frames and expansion never causes another detector invocation.
    capture_config = replace(config, window_before=config.max_window_before)
    groups = merge_event_windows(events, capture_config, info.duration)
    frames = []
    for j, group in enumerate(groups):
        for index, timestamp, frame in iter_video_frames(
            video, group["start"], group["end"], config.sample_fps, info
        ):
            players = player_detector.detect(frame, timestamp)
            if hasattr(ball_detector, "detect_with_players"):
                balls = ball_detector.detect_with_players(frame, timestamp, players)
            else:
                balls = ball_detector.detect(frame, timestamp)
            frames.append(
                {
                    "frame_index": index,
                    "timestamp": timestamp,
                    "players": [d.to_dict() for d in players],
                    "balls": [d.to_dict() for d in balls],
                }
            )
        if progress:
            progress((j + 1) / len(groups))
    return {
        "schema_version": 1,
        "video_fingerprint": video_fingerprint(video),
        "video_info": asdict(info),
        "coordinate_system": "source_decoded_pixels_xyxy",
        "sample_fps": min(config.sample_fps, info.fps),
        "windows": [[g["start"], g["end"]] for g in groups],
        "models": models or {},
        "elapsed_seconds": time.perf_counter() - started,
        "frames": frames,
    }
