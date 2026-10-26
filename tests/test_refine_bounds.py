"""精修阶段的越界防护测试。

竖拍视频的篮筐几何容易推出超出 ROI 的检测区域，之前会切出空图并让
cv2.cvtColor 断言失败，整个分析随之中断。
"""

import sys
from pathlib import Path

import cv2
import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "scripts"))

import refine_candidates  # noqa: E402


def _frame(height=720, width=1280):
    return np.full((height, width, 3), 40, dtype=np.uint8)


class _NoDetections:
    boxes = []


class _Model:
    def predict(self, crops, **kwargs):
        return [_NoDetections() for _ in crops]


def _video(tmp_path: Path, width=640, height=480) -> Path:
    path = tmp_path / "clip.mp4"
    writer = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"mp4v"), 30, (width, height))
    for index in range(90):
        frame = _frame(height, width)
        cv2.circle(frame, (200 + index * 2, 150 + index), 20, (0, 120, 255), -1)
        writer.write(frame)
    writer.release()
    return path


def _scan(video: Path, roi, rim):
    return refine_candidates.scan_window(
        _Model(), video, roi, 1.5, 1.5, 5, 1, 0.15, "cpu", rim=rim, batch=8,
    )


def test_a_hoop_outside_the_decoded_frame_skips_the_net_signal_instead_of_crashing(tmp_path: Path):
    """ROI 和篮筐超出实际解码的画面时，之前 cv2.cvtColor 对空图断言失败，整个精修中断。"""
    records = _scan(
        _video(tmp_path),
        (100, 100, 400, 700),
        {"center_x": 250.0, "rim_y": 520.0, "width": 90.0, "height": 40.0},
    )

    assert records
    assert not any(record["net_measurement_valid"] for record in records)


def test_a_hoop_inside_the_frame_still_measures_the_net(tmp_path: Path):
    records = _scan(
        _video(tmp_path),
        (100, 100, 400, 400),
        {"center_x": 250.0, "rim_y": 200.0, "width": 90.0, "height": 40.0},
    )

    assert any(record["net_measurement_valid"] for record in records)


def test_net_zones_stay_inside_the_frame_for_portrait_video():
    """竖拍(720x1512)贴边篮筐不应推出画面外的坐标。"""
    frame = _frame(height=1512, width=720)
    rim = {"center_x": 700.0, "rim_y": 100.0, "width": 80.0, "height": 30.0}
    zones = refine_candidates._net_zones(
        rim,
        frame.shape[1],
        frame.shape[0],
        net_roi=None,
    )
    for left, top, right, bottom in zones.values():
        assert 0 <= left < right <= frame.shape[1]
        assert 0 <= top < bottom <= frame.shape[0]
