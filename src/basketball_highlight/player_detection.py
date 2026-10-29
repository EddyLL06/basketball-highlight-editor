"""Replaceable frame detectors. All boxes are xyxy in original decoded-frame pixels.

Timestamps are source-video seconds. Importing this module does not load torch,
OpenCV or a model. Weights must already exist locally; inference never downloads.
"""

from __future__ import annotations

import math
import os
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Protocol


@dataclass(frozen=True)
class Detection:
    timestamp: float
    bbox: tuple[float, float, float, float]
    confidence: float
    appearance: tuple[float, ...] | None = None

    def __post_init__(self):
        if (
            len(self.bbox) != 4
            or not all(
                math.isfinite(v) for v in (*self.bbox, self.timestamp, self.confidence)
            )
            or self.timestamp < 0
            or not 0 <= self.confidence <= 1
            or self.bbox[2] <= self.bbox[0]
            or self.bbox[3] <= self.bbox[1]
        ):
            raise ValueError("ATTRIBUTION_DETECTION_INVALID")
        if self.appearance is not None and (
            not self.appearance
            or any(not math.isfinite(v) or v < 0 for v in self.appearance)
            or abs(sum(self.appearance) - 1) > 0.01
        ):
            raise ValueError("ATTRIBUTION_APPEARANCE_INVALID")

    @property
    def center(self) -> tuple[float, float]:
        x1, y1, x2, y2 = self.bbox
        return (x1 + x2) / 2, (y1 + y2) / 2

    @property
    def height(self) -> float:
        return self.bbox[3] - self.bbox[1]

    def to_dict(self) -> dict:
        result = {
            "timestamp": self.timestamp,
            "bbox": list(self.bbox),
            "confidence": self.confidence,
        }
        if self.appearance is not None:
            result["appearance"] = list(self.appearance)
        return result

    @classmethod
    def from_dict(cls, value):
        return cls(
            float(value["timestamp"]),
            tuple(value["bbox"]),
            float(value["confidence"]),
            tuple(value["appearance"]) if value.get("appearance") is not None else None,
        )


def torso_signature(frame, bbox) -> tuple[float, ...] | None:
    """Coarse HSV histogram of the inner torso, scoped to one local session.

    No faces, OCR, embedding model or cross-clip identity database are involved.
    Value bins retain black/white clothing evidence when hue is uninformative.
    """
    import cv2
    import numpy as np

    height, width = frame.shape[:2]
    x1, y1, x2, y2 = bbox
    box_width, box_height = x2 - x1, y2 - y1
    left, right = (
        max(0, round(x1 + box_width * 0.2)),
        min(width, round(x2 - box_width * 0.2)),
    )
    top, bottom = (
        max(0, round(y1 + box_height * 0.18)),
        min(height, round(y1 + box_height * 0.52)),
    )
    crop = frame[top:bottom:2, left:right:2]
    if crop.size < 48:
        return None
    hsv = cv2.cvtColor(crop, cv2.COLOR_BGR2HSV)
    hue = np.minimum(hsv[:, :, 0].astype(int) * 4 // 180, 3)
    sat = np.minimum(hsv[:, :, 1].astype(int) * 2 // 256, 1)
    value = np.minimum(hsv[:, :, 2].astype(int) * 8 // 256, 7)
    counts = np.bincount((hue * 16 + sat * 8 + value).ravel(), minlength=64)
    return tuple(float(v) for v in counts / counts.sum())


class FrameDetector(Protocol):
    def detect(self, frame: Any, timestamp: float) -> list[Detection]: ...


def normalize_detection(
    timestamp, bbox, confidence, *, scale=(1.0, 1.0), offset=(0.0, 0.0), frame_size=None
) -> Detection:
    """Map detector/cached coordinates to source pixels, then clip to the frame.

    scale is source pixels per input pixel (not the resize multiplier).
    offset is the source crop origin; model letterboxing is undone by the backend.
    """
    if len(bbox) != 4 or any(not math.isfinite(v) or v <= 0 for v in scale):
        raise ValueError("ATTRIBUTION_TRANSFORM_INVALID")
    coords = [float(v) * scale[i % 2] + offset[i % 2] for i, v in enumerate(bbox)]
    if not all(math.isfinite(v) for v in coords):
        raise ValueError("ATTRIBUTION_TRANSFORM_INVALID")
    if frame_size:
        coords = [min(max(v, 0.0), frame_size[i % 2]) for i, v in enumerate(coords)]
    return Detection(float(timestamp), tuple(coords), float(confidence))


class LocalYoloDetector:
    """Use BHE's device/backend factory, with labels resolved from model metadata.

    Use a separate instance with label='person' for players and label='ball' for
    the unchanged BHE model. No class IDs leak into the association pipeline.
    """

    def __init__(
        self,
        model_path,
        *,
        label="person",
        device="auto",
        confidence=0.15,
        imgsz=640,
        tiles=1,
    ):
        path = Path(model_path)
        if not path.is_file():
            raise ValueError(f"MODEL_NOT_FOUND: {path}; supply existing local weights")
        if (
            not 0 < confidence < 1
            or imgsz < 320
            or imgsz % 32
            or tiles not in (1, 2, 3)
        ):
            raise ValueError("ATTRIBUTION_DETECTOR_PARAMETERS_INVALID")
        # Ultralytics may otherwise try pip/network when a checkpoint needs a
        # missing optional package. Missing dependencies must fail locally.
        os.environ["YOLO_AUTOINSTALL"] = "false"
        from .inference import current_device, load_detector, select_device

        target = select_device(device, path)
        self.model = load_detector(path, device=target)
        self.device = current_device()
        names = self.model.names
        items = names.items() if isinstance(names, dict) else enumerate(names)
        self.classes = [
            int(i) for i, name in items if str(name).strip().lower() == label
        ]
        if not self.classes:
            raise ValueError(
                f"MODEL_LABEL_MISSING: {label}; use weights with correct class metadata"
            )
        self.confidence, self.imgsz, self.tiles, self.label = (
            confidence,
            imgsz,
            tiles,
            label,
        )

    def detect(self, frame, timestamp) -> list[Detection]:
        height, width = frame.shape[:2]
        # Overlapping tiles retain small balls near the shooter. Person detection
        # always defaults to a full frame, independent of BHE's hoop ROI.
        crops = [(0, 0, width, height)]
        if self.tiles > 1:
            side_x, side_y = (
                math.ceil(width / self.tiles * 1.2),
                math.ceil(height / self.tiles * 1.2),
            )
            crops += [
                (
                    round((width - side_x) * x / (self.tiles - 1)),
                    round((height - side_y) * y / (self.tiles - 1)),
                    side_x,
                    side_y,
                )
                for y in range(self.tiles)
                for x in range(self.tiles)
            ]
        return self.detect_regions(frame, timestamp, crops)

    def detect_regions(self, frame, timestamp, crops):
        """Infer explicit (left, top, width, height) source-frame regions."""
        height, width = frame.shape[:2]
        detections = []
        for left, top, crop_width, crop_height in crops:
            result = self.model.predict(
                frame[top : top + crop_height, left : left + crop_width],
                device=self.device,
                conf=self.confidence,
                imgsz=self.imgsz,
                rect=False,
                verbose=False,
            )[0]
            for box in result.boxes:
                if int(box.cls[0]) not in self.classes:
                    continue
                try:
                    detection = normalize_detection(
                        timestamp,
                        box.xyxy[0].tolist(),
                        float(box.conf[0]),
                        offset=(left, top),
                        frame_size=(width, height),
                    )
                except ValueError:
                    continue
                if self.label == "person":
                    detection = replace(
                        detection, appearance=torso_signature(frame, detection.bbox)
                    )
                detections.append(detection)
        if len(crops) == 1:
            return detections
        # Suppress duplicate detections from tile overlaps, preserving alternatives.
        from .player_tracking import bbox_iou

        kept = []
        for detection in sorted(detections, key=lambda d: (-d.confidence, d.bbox)):
            if all(
                bbox_iou(detection.bbox, other.bbox) < 0.5
                and (
                    self.label != "ball"
                    or math.dist(detection.center, other.center)
                    > 0.5 * min(detection.height, other.height)
                )
                for other in kept
            ):
                kept.append(detection)
        return kept


class PlayerGuidedBallDetector:
    """Full-frame flight search plus bounded upper-body crops for release evidence."""

    def __init__(self, detector: LocalYoloDetector, max_players=12):
        self.detector, self.max_players = detector, max_players
        self.device = detector.device

    def detect(self, frame, timestamp):
        return self.detector.detect(frame, timestamp)

    def detect_with_players(self, frame, timestamp, players):
        height, width = frame.shape[:2]
        crops = [(0, 0, width, height)]
        for player in sorted(players, key=lambda d: -d.confidence)[: self.max_players]:
            x1, y1, x2, y2 = player.bbox
            side = max(player.height * 1.45, (x2 - x1) * 2)
            cx, cy = (x1 + x2) / 2, y1 + player.height * 0.12
            left, top = max(0, round(cx - side / 2)), max(0, round(cy - side / 2))
            right, bottom = (
                min(width, round(cx + side / 2)),
                min(height, round(cy + side / 2)),
            )
            if right - left >= 32 and bottom - top >= 32:
                crops.append((left, top, right - left, bottom - top))
        return self.detector.detect_regions(frame, timestamp, crops)
