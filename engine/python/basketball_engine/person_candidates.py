"""Bounded person candidates near an approximate release; never infer identities.

The detector only receives cropped pixels, at most twice per selected frame.
Missing launch evidence or an oversized region stays a manual-review case.
"""

from __future__ import annotations

import hashlib
import math
import os
import time
from dataclasses import dataclass
from pathlib import Path

from .adapters.analysis import PipelineCancelled
from .protocol import ProtocolError

PERSON_MODEL_NAME = "yolo11n.pt"
PERSON_MODEL_SHA256 = "0ebbc80d4a7680d14987a577cd21342b65ecfd94632bd9a8da63ae6417644ee1"


@dataclass(frozen=True)
class RegionPolicy:
    retry_scale: float = 1.2
    max_area_fraction: float = 0.5
    min_side: int = 16
    min_confidence: float = 0.2
    max_people: int = 12

    def __post_init__(self):
        if not (
            1 < self.retry_scale <= 1.35
            and 0 < self.max_area_fraction <= 0.5
            and type(self.min_side) is int
            and self.min_side >= 4
            and 0 < self.min_confidence < 1
            and type(self.max_people) is int
            and 1 <= self.max_people <= 16
        ):
            raise ValueError("PERSON_REGION_POLICY_INVALID")


def clipped_region(region, width, height):
    try:
        if len(region) != 4 or not all(math.isfinite(float(v)) for v in region):
            return None
        x1, y1, x2, y2 = map(float, region)
        box = (
            max(0, min(width, math.floor(x1))),
            max(0, min(height, math.floor(y1))),
            max(0, min(width, math.ceil(x2))),
            max(0, min(height, math.ceil(y2))),
        )
        return box if box[2] > box[0] and box[3] > box[1] else None
    except (TypeError, ValueError, OverflowError):
        return None


def release_distance(box, point):
    """Distance to an upper-body envelope, not a shooter probability."""
    if not point:
        return None
    try:
        x, y = float(point[0]), float(point[1])
        if not all(math.isfinite(v) for v in (x, y)):
            return None
    except (IndexError, TypeError, ValueError):
        return None
    x1, y1, x2, y2 = box
    w, h = x2 - x1, y2 - y1
    dx = max(x1 - w * 0.15 - x, 0, x - x2 - w * 0.15)
    dy = max(y1 - h * 0.25 - y, 0, y - y1 - h * 0.5)
    return math.hypot(dx, dy) / max(h, 1)


def person_search_region(region, width, height, *, release_point=None, basis=None):
    """Use a smaller body region only for directly observed upward ball motion.

    The observed-motion basis is a conservative gate, not a calibrated confidence.
    Back-projected or edge-adjacent releases retain their wider context.
    """
    original = clipped_region(region, width, height)
    fallback = (original, "approximate_release_region_v1")
    if original is None or basis != "upward_ball_motion_estimate":
        return fallback
    try:
        x, y = map(float, release_point)
        if not all(math.isfinite(v) for v in (x, y)):
            return fallback
    except (TypeError, ValueError, OverflowError):
        return fallback
    x1, y1, x2, y2 = original
    if not (x1 <= x <= x2 and y1 <= y <= y2 and width * 0.14 <= x <= width * 0.86):
        return fallback
    w, h = min(x2 - x1, width * 0.28), min(y2 - y1, height * 0.66)
    left = max(x1, min(x2 - w, x - w / 2))
    top = max(y1, min(y2 - h, y - h * (0.27 / 0.76)))
    compact = clipped_region((left, top, left + w, top + h), width, height)
    return compact, "observed_release_compact_v1"


class RegionPersonCandidates:
    def __init__(self, detector, policy=None):
        self.detector = detector
        self.policy = policy or RegionPolicy()

    def infer(self, frame, region, *, release_point=None, cancel=None):
        if frame.ndim != 3 or frame.shape[2] != 3:
            raise ValueError("PERSON_FRAME_INVALID")
        height, width = frame.shape[:2]
        policy = self.policy
        start = time.perf_counter()
        result = {
            "status": "no_release_region",
            "people": [],
            "regions": [],
            "attempts": 0,
            "elapsed_ms": 0,
            "examined_pixels": 0,
            "detector": getattr(self.detector, "metadata", {}),
        }
        box = clipped_region(region, width, height)
        if box is None:
            return result
        x1, y1, x2, y2 = box
        cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
        for scale in (1.0, policy.retry_scale):
            if cancel and cancel.is_set():
                raise PipelineCancelled("JOB_CANCELLED")
            half_w, half_h = (x2 - x1) * scale / 2, (y2 - y1) * scale / 2
            crop_box = clipped_region(
                (cx - half_w, cy - half_h, cx + half_w, cy + half_h), width, height
            )
            if crop_box in result["regions"]:
                break
            left, top, right, bottom = crop_box
            area = (right - left) * (bottom - top)
            if (
                min(right - left, bottom - top) < policy.min_side
                or area > width * height * policy.max_area_fraction
            ):
                result["status"] = (
                    "region_outside_budget" if not result["attempts"] else "no_person"
                )
                break
            result["regions"].append(crop_box)
            result["attempts"] += 1
            # A copy isolates the source pixels from detector/preprocessing code.
            detections = self.detector.detect(frame[top:bottom, left:right].copy())
            people = []
            for detection in detections:
                try:
                    score = float(detection["confidence"])
                    local = clipped_region(
                        detection["bbox"], right - left, bottom - top
                    )
                    if (
                        local is None
                        or not math.isfinite(score)
                        or not policy.min_confidence <= score <= 1
                    ):
                        continue
                except (KeyError, TypeError, ValueError, OverflowError):
                    continue
                a, b, c, d = local
                mapped = [a + left, b + top, c + left, d + top]
                people.append(
                    {
                        "bbox": mapped,
                        "confidence": score,
                        "release_distance": release_distance(mapped, release_point),
                        "touches_region_edge": min(
                            a, b, right - left - c, bottom - top - d
                        )
                        <= 2,
                    }
                )
            if people:
                people.sort(
                    key=lambda p: (
                        p["release_distance"]
                        if p["release_distance"] is not None
                        else math.inf,
                        -p["confidence"],
                        p["bbox"],
                    )
                )
                result.update(status="detected", people=people[: policy.max_people])
                break
            result["status"] = "no_person"
        result["elapsed_ms"] = round((time.perf_counter() - start) * 1000, 3)
        result["examined_pixels"] = sum(
            (r - l) * (b - t) for l, t, r, b in result["regions"]
        )
        return result


def person_model_path():
    explicit = os.environ.get("BHE_PERSON_MODEL")
    root = Path(
        os.environ.get("BHE_RUNTIME_ROOT") or Path(__file__).resolve().parents[3]
    )
    path = (
        Path(explicit).expanduser() if explicit else root / "models" / PERSON_MODEL_NAME
    )
    if not path.is_file():
        raise ProtocolError(
            "PERSON_MODEL_MISSING", "人物候选模型未安装，仍可继续人工标注"
        )
    return path.resolve()


class YoloPersonCropDetector:
    """One local, verified checkpoint per job/session; no runtime downloads."""

    def __init__(self, weights, *, device="auto", imgsz=320):
        weights = Path(weights)
        if not weights.is_file():
            raise ProtocolError("PERSON_MODEL_MISSING", "人物候选模型未安装")
        if not isinstance(imgsz, int) or not 160 <= imgsz <= 640 or imgsz % 32:
            raise ValueError("PERSON_INPUT_SIZE_INVALID")
        digest = hashlib.sha256()
        with weights.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != PERSON_MODEL_SHA256:
            raise ProtocolError(
                "PERSON_MODEL_INVALID", "人物候选模型校验失败，请重新准备模型"
            )
        os.environ["YOLO_AUTOINSTALL"] = "false"
        from basketball_highlight.inference import (
            current_device,
            load_detector,
            select_device,
        )

        target = select_device(device, weights)
        self.model = load_detector(weights, device=target, imgsz=imgsz)
        self.device, self.imgsz = current_device(), imgsz
        names = self.model.names
        items = names.items() if isinstance(names, dict) else enumerate(names)
        self.classes = [
            int(i) for i, name in items if str(name).strip().lower() == "person"
        ]
        if not self.classes:
            raise ProtocolError("PERSON_MODEL_INVALID", "当前模型不支持人物检测")
        self.metadata = {
            "model": PERSON_MODEL_NAME,
            "sha256": PERSON_MODEL_SHA256,
            "input_size": imgsz,
            "device": self.device,
        }

    def detect(self, crop):
        result = self.model.predict(
            crop,
            device=self.device,
            imgsz=self.imgsz,
            conf=0.2,
            classes=self.classes,
            max_det=12,
            rect=True,
            verbose=False,
        )[0]
        return [
            {"bbox": box.xyxy[0].tolist(), "confidence": float(box.conf[0])}
            for box in result.boxes
            if int(box.cls[0]) in self.classes
        ]
