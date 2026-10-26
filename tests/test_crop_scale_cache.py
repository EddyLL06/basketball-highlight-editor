"""#9 改了裁切放大倍数，粗扫缓存不能把旧倍数的结果当成新结果用。"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "scripts"))

import scan_video  # noqa: E402
from engine.python.basketball_engine.media_tools import resolve_media_tool  # noqa: E402


class _NoDetections:
    boxes = []
    names = {0: "ball"}


class _Model:
    def __init__(self, scales):
        self.scales = scales

    def predict(self, crops, **kwargs):
        self.scales.append(crops[0].shape[1] / 400)
        return [_NoDetections() for _ in crops]


def _args(tmp_path: Path, video: Path) -> argparse.Namespace:
    model = tmp_path / "model.pt"
    model.write_bytes(b"pt")
    return argparse.Namespace(
        video=str(video), model=str(model), roi=[0, 0, 400, 300], sample_fps=5.0,
        duration=None, time_offset=0.0, scale=4, batch=8, conf=0.15, device="cpu",
        cache_dir=tmp_path / "cache", output=str(tmp_path / "coarse.json"),
    )


def test_switching_the_compat_scale_does_not_reuse_the_other_cache(tmp_path: Path, monkeypatch):
    ffmpeg = resolve_media_tool("ffmpeg")
    if not shutil.which(ffmpeg):
        pytest.skip("需要 ffmpeg")
    video = tmp_path / "clip.mp4"
    subprocess.run(
        [ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=640x480:rate=10",
         "-t", "1", "-c:v", "mpeg4", str(video)],
        check=True,
    )
    scales = []
    monkeypatch.setattr(scan_video, "load_yolo_model", lambda path: _Model(scales))
    monkeypatch.setattr(scan_video, "select_device", lambda device: "cpu")
    args = _args(tmp_path, video)

    monkeypatch.setenv("BHE_CROP_SCALE_COMPAT", "1")
    scan_video.scan_video(args)
    monkeypatch.delenv("BHE_CROP_SCALE_COMPAT")
    scan_video.scan_video(args)
    calls_after_switch = len(scales)
    scan_video.scan_video(args)

    # 旧倍数 4，新倍数把 400 宽的裁切放大到刚好 640（1.6 倍）；切换后要重新跑，相同设置再跑才命中缓存。
    assert sorted(set(round(value, 1) for value in scales)) == [1.6, 4.0]
    assert len(scales) == calls_after_switch
