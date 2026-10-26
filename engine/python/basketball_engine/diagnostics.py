"""写给桌面端运行日志的诊断信息：走 stderr，桌面端逐行记进 engine.log。"""

from __future__ import annotations

import os
import platform
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict

from . import __version__
from .media_tools import resolve_media_tool


def log_diagnostic(message: str) -> None:
    print(f"[bhe] {message}", file=sys.stderr, flush=True)


def folder_summary(path: Path) -> str:
    """建目录失败时，记下路径上每一级是否存在，到第一个已存在的上级为止。

    用来区分「上级不存在」「上级是失效的链接 / 重解析点（OneDrive、被挪走的视频文件夹）」
    和「上级好好的但被拦截」（受控文件夹访问、安全软件）。
    """
    parts = []
    for item in (path, *path.parents):
        try:
            info = os.lstat(item)
        except OSError as exc:
            parts.append(f"{item}: missing({exc.__class__.__name__})")
            continue
        reparse = bool(getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT)
        parts.append(
            f"{item}: dir={item.is_dir()} link={stat.S_ISLNK(info.st_mode)} reparse={reparse}"
        )
        break
    return " | ".join(parts)


def video_summary(video: Dict[str, Any]) -> str:
    fps = float(video.get("fps") or 0)
    duration = (video.get("duration_ms") or 0) / 1000
    size_mb = (video.get("source_size_bytes") or 0) / 1024 / 1024
    return (
        f"{video.get('width')}x{video.get('height')} {fps:.2f}fps "
        f"video={video.get('video_codec')} audio={video.get('audio_codec')} "
        f"duration={duration:.1f}s size={size_mb:.0f}MB"
    )


def _total_memory_bytes() -> int | None:
    try:
        if os.name == "nt":
            import ctypes

            class MemoryStatus(ctypes.Structure):
                _fields_ = [
                    ("length", ctypes.c_ulong),
                    ("memory_load", ctypes.c_ulong),
                    ("total_phys", ctypes.c_ulonglong),
                    ("avail_phys", ctypes.c_ulonglong),
                    ("total_page_file", ctypes.c_ulonglong),
                    ("avail_page_file", ctypes.c_ulonglong),
                    ("total_virtual", ctypes.c_ulonglong),
                    ("avail_virtual", ctypes.c_ulonglong),
                    ("avail_extended_virtual", ctypes.c_ulonglong),
                ]

            status = MemoryStatus()
            status.length = ctypes.sizeof(MemoryStatus)
            if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
                return None
            return int(status.total_phys)
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    except (AttributeError, OSError, ValueError):
        return None


def _ffmpeg_version(ffmpeg: str) -> str:
    try:
        completed = subprocess.run(
            [ffmpeg, "-hide_banner", "-version"],
            capture_output=True,
            stdin=subprocess.DEVNULL,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return f"unavailable ({exc})"
    lines = completed.stdout.splitlines()
    return lines[0] if lines else f"unknown (exit={completed.returncode})"


def environment_summary() -> str:
    memory = _total_memory_bytes()
    ffmpeg = resolve_media_tool("ffmpeg")
    return (
        f"environment engine={__version__} python={platform.python_version()} "
        f"os={platform.platform()} machine={platform.machine()} cpu={os.cpu_count()} "
        f"memory={f'{memory / 1024 ** 3:.1f}GB' if memory else 'unknown'} "
        f"ffmpeg={ffmpeg} ({_ffmpeg_version(ffmpeg)})"
    )
