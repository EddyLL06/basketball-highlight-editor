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


def _windows_cpu_features():
    features = {"avx": "unknown", "avx2": "unknown", "avx512f": "unknown"}
    try:
        import ctypes

        if sys.getwindowsversion().build < 19041:
            return features
        probe = ctypes.windll.kernel32.IsProcessorFeaturePresent
        probe.argtypes = [ctypes.c_uint32]
        probe.restype = ctypes.c_int
        for name, feature in (("avx", 39), ("avx2", 40), ("avx512f", 41)):
            try:
                features[name] = "true" if probe(feature) else "false"
            except Exception:
                pass
    except Exception:
        pass
    return features


def _windows_msvcp_version():
    try:
        import ctypes

        class FixedFileInfo(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint32) for name in (
                "signature", "struct_version", "file_version_ms", "file_version_ls",
                "product_version_ms", "product_version_ls", "flags_mask", "flags",
                "os", "type", "subtype", "date_ms", "date_ls",
            )]

        kernel = ctypes.windll.kernel32
        kernel.GetSystemDirectoryW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32]
        kernel.GetSystemDirectoryW.restype = ctypes.c_uint32
        directory = ctypes.create_unicode_buffer(32768)
        length = kernel.GetSystemDirectoryW(directory, len(directory))
        if not 0 < length < len(directory):
            return "unknown"
        path = directory.value + "\\msvcp140.dll"
        version = ctypes.windll.version
        version.GetFileVersionInfoSizeW.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_uint32)]
        version.GetFileVersionInfoSizeW.restype = ctypes.c_uint32
        size = version.GetFileVersionInfoSizeW(path, None)
        if not size:
            return "unknown"
        version.GetFileVersionInfoW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
        version.GetFileVersionInfoW.restype = ctypes.c_int
        data = ctypes.create_string_buffer(size)
        if not version.GetFileVersionInfoW(path, 0, size, data):
            return "unknown"
        version.VerQueryValueW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p,
                                         ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_uint32)]
        version.VerQueryValueW.restype = ctypes.c_int
        block = ctypes.c_void_p()
        block_length = ctypes.c_uint32()
        if not version.VerQueryValueW(data, "\\", ctypes.byref(block), ctypes.byref(block_length)):
            return "unknown"
        if not block.value or block_length.value < ctypes.sizeof(FixedFileInfo):
            return "unknown"
        info = ctypes.cast(block, ctypes.POINTER(FixedFileInfo)).contents
        if info.signature != 0xFEEF04BD:
            return "unknown"
        return ".".join(str(value) for value in (
            info.file_version_ms >> 16, info.file_version_ms & 0xffff,
            info.file_version_ls >> 16, info.file_version_ls & 0xffff,
        ))
    except Exception:
        return "unknown"


def _windows_environment():
    return " " + " ".join(f"{key}={value}" for key, value in {
        **_windows_cpu_features(), "msvcp140": _windows_msvcp_version(),
    }.items())


def environment_summary() -> str:
    memory = _total_memory_bytes()
    ffmpeg = resolve_media_tool("ffmpeg")
    return (
        f"environment engine={__version__} python={platform.python_version()} "
        f"os={platform.platform()} machine={platform.machine()} cpu={os.cpu_count()} "
        f"memory={f'{memory / 1024 ** 3:.1f}GB' if memory else 'unknown'} "
        f"ffmpeg={ffmpeg} ({_ffmpeg_version(ffmpeg)})"
        f"{_windows_environment() if platform.system() == 'Windows' else ''}"
    )
