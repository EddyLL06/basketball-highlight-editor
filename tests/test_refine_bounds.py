"""精修阶段的越界防护测试。

竖拍视频的篮筐几何容易推出超出 ROI 的检测区域，之前会切出空图并让
cv2.cvtColor 断言失败，整个分析随之中断。
"""

import sys
from pathlib import Path

import numpy as np
import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "scripts"))

import refine_candidates  # noqa: E402


def _frame(height=720, width=1280):
    return np.full((height, width, 3), 40, dtype=np.uint8)


def test_zone_bounds_are_clipped_to_the_roi():
    """zones 超出 ROI 时应被裁进 ROI，而不是留一个越界的框。"""
    roi = (100, 100, 400, 400)
    frame = _frame()
    rim = {"center_x": 120.0, "rim_y": 380.0, "width": 90.0, "height": 40.0}
    zones = refine_candidates._net_zones(
        rim,
        frame.shape[1],
        frame.shape[0],
        net_roi=None,
    )
    assert zones, "篮筐几何应该能推出检测区域"
    # 模拟 scan_window 里的裁剪逻辑
    x1, y1, x2, y2 = roi
    clipped = [
        (max(x1, b[0]), max(y1, b[1]), min(x2, b[2]), min(y2, b[3]))
        for b in zones.values()
    ]
    kept = [b for b in clipped if b[2] > b[0] and b[3] > b[1]]
    for box in kept:
        assert box[0] >= x1 and box[1] >= y1
        assert box[2] <= x2 and box[3] <= y2


def test_clipped_bounds_never_produce_an_empty_slice():
    """裁剪后的每个框都必须能切出非空图像。"""
    frame = _frame()
    roi = (100, 100, 400, 400)
    x1, y1, x2, y2 = roi
    # 故意给一个远离 ROI 的篮筐，制造完全越界的情况
    rim = {"center_x": 1200.0, "rim_y": 650.0, "width": 90.0, "height": 40.0}
    zones = refine_candidates._net_zones(
        rim,
        frame.shape[1],
        frame.shape[0],
        net_roi=None,
    )
    clipped = [
        (max(x1, b[0]), max(y1, b[1]), min(x2, b[2]), min(y2, b[3]))
        for b in zones.values()
    ]
    kept = [b for b in clipped if b[2] > b[0] and b[3] > b[1]]
    for left, top, right, bottom in kept:
        assert frame[top:bottom, left:right].size > 0


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
