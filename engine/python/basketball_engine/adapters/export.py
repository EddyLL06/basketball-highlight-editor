from __future__ import annotations

import platform
import re
import subprocess
import threading
import time
from collections import deque
from pathlib import Path
from typing import Any, Dict
from uuid import uuid4

from .analysis import PipelineCancelled, terminate_process
from ..media_tools import resolve_media_tool


# NVIDIA, Intel, AMD, then the Windows Media Foundation encoder, which works
# on any GPU and falls back to Microsoft's software encoder.
WINDOWS_HARDWARE_CODECS = ("h264_nvenc", "h264_qsv", "h264_amf", "h264_mf")

# FFmpeg only prints the useful part of a failure (missing decoder, encoder
# init error) in the last few lines, so keep a short tail for the job record.
STDERR_TAIL_LINES = 40


class MediaCommandError(subprocess.CalledProcessError):
    """FFmpeg failure that keeps the stderr tail in its message."""

    def __init__(self, returncode: int, command: list[str], stderr_tail: str = ""):
        super().__init__(returncode, command, output=None, stderr=stderr_tail or None)
        self.stderr_tail = stderr_tail

    def __str__(self) -> str:
        message = super().__str__()
        tail = (self.stderr_tail or "").strip()
        return f"{message}\n{tail}" if tail else message


def _collect_stderr(stream, tail: deque[str]) -> None:
    try:
        for line in stream:
            text = line.rstrip()
            if text:
                tail.append(text)
    except (OSError, ValueError):
        pass


def video_codecs() -> list[str]:
    hardware = {
        "Darwin": ("h264_videotoolbox",),
        "Windows": WINDOWS_HARDWARE_CODECS,
    }.get(platform.system(), ())
    # The bundled Windows LGPL FFmpeg has no libx264. Keep H.264 when
    # available, then use high-quality MPEG-4 rather than failing the export.
    return list(dict.fromkeys((*hardware, "libx264", "libopenh264", "mpeg4")))


def video_codec_options(codec: str) -> list[str]:
    options = ["-c:v", codec]
    if codec == "libx264":
        options += ["-preset", "veryfast", "-crf", "22"]
    elif codec == "libopenh264":
        options += ["-b:v", "8M"]
    elif codec == "mpeg4":
        options += ["-q:v", "2"]
    elif codec in WINDOWS_HARDWARE_CODECS:
        options += ["-b:v", "16M", "-maxrate", "24M", "-bufsize", "32M"]
    return options


def run_encoded_ffmpeg(command_builder, output_path: Path, codecs: list[str], **kwargs) -> str:
    """Encode with the first codec that works and return it."""
    for index, codec in enumerate(codecs):
        try:
            run_atomic_ffmpeg(command_builder(codec), output_path, **kwargs)
            return codec
        except subprocess.CalledProcessError:
            if index == len(codecs) - 1:
                raise


def concat_manifest_entry(path: Path) -> str:
    """Render a path safely for the ffmpeg concat demuxer on macOS and Windows."""
    normalized = path.resolve().as_posix().replace("'", "'\\''")
    return f"file '{normalized}'\n"


def available_output_path(path: Path) -> Path:
    if not path.exists():
        return path
    for index in range(2, 10_000):
        candidate = path.with_name(f"{path.stem}_{index}{path.suffix}")
        if not candidate.exists():
            return candidate
    raise OSError(f"无法生成不冲突的导出文件名: {path}")


def clip_file_name(index: int, candidate: Dict[str, Any]) -> str:
    name = f"goal_{index:03d}_{candidate['event_time_ms'] / 1000:.2f}s"
    player = re.sub(r'[\x00-\x1f<>:"/\\|?*]+', "_", str(candidate.get("player_name") or ""))
    player = player.strip(" ._")[:40]
    return f"{name}_{player}.mp4" if player else f"{name}.mp4"


def build_clip_command(
    source_video: Path,
    start_ms: int,
    end_ms: int,
    output_path: Path,
    video_codec: str | None = None,
) -> list[str]:
    if start_ms < 0 or end_ms <= start_ms:
        raise ValueError("INVALID_CLIP_RANGE")
    duration = (end_ms - start_ms) / 1000
    codec = video_codec or video_codecs()[0]
    codec_options = video_codec_options(codec)
    command = [
        resolve_media_tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
        "-ss", f"{start_ms / 1000:.3f}", "-i", str(source_video),
        "-t", f"{duration:.3f}",
        # Only the first audio track: iPhone spatial audio (APAC) and similar
        # tracks have no decoder here and would abort the whole export.
        "-map", "0:v:0?", "-map", "0:a:0?",
        *codec_options, "-c:a", "aac", "-b:a", "128k",
        "-movflags", "+faststart", str(output_path),
    ]
    return command


def validate_media_file(path: Path) -> None:
    if not path.is_file() or path.stat().st_size <= 0:
        raise OSError(f"导出文件为空: {path}")
    result = subprocess.run(
        [
            resolve_media_tool("ffprobe"), "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        check=True,
        capture_output=True,
        stdin=subprocess.DEVNULL,
        text=True,
        timeout=15,
    )
    try:
        duration = float(result.stdout.strip())
    except ValueError as exc:
        raise OSError(f"导出文件时长无效: {path}") from exc
    if duration <= 0:
        raise OSError(f"导出文件时长为零: {path}")


def run_atomic_ffmpeg(
    command: list[str],
    output_path: Path,
    cancel_check=None,
    process_callback=None,
) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = output_path.with_name(
        f".{output_path.stem}.{uuid4().hex}.part{output_path.suffix}"
    )
    atomic_command = [*command[:-1], str(temporary)]
    try:
        popen_kwargs = {
            "stdin": subprocess.DEVNULL,
            "stderr": subprocess.PIPE,
            "text": True,
            "errors": "replace",
        }
        if platform.system() == "Windows":
            popen_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
        else:
            popen_kwargs["start_new_session"] = True
        process = subprocess.Popen(atomic_command, **popen_kwargs)
        # Drain stderr in a thread so a full pipe can never block FFmpeg.
        stderr_tail: deque[str] = deque(maxlen=STDERR_TAIL_LINES)
        stderr_stream = getattr(process, "stderr", None)
        reader = None
        if stderr_stream is not None:
            reader = threading.Thread(
                target=_collect_stderr,
                args=(stderr_stream, stderr_tail),
                name="ffmpeg-stderr",
                daemon=True,
            )
            reader.start()
        if process_callback:
            process_callback(process)
        try:
            while process.poll() is None:
                if cancel_check and cancel_check():
                    terminate_process(process)
                    raise PipelineCancelled("JOB_CANCELLED")
                time.sleep(0.05)
            if cancel_check and cancel_check():
                raise PipelineCancelled("JOB_CANCELLED")
            if process.returncode != 0:
                if reader is not None:
                    reader.join(timeout=2)
                raise MediaCommandError(
                    process.returncode,
                    atomic_command,
                    "\n".join(stderr_tail),
                )
        finally:
            if process_callback:
                process_callback(None)
            if stderr_stream is not None:
                stderr_stream.close()
        validate_media_file(temporary)
        temporary.replace(output_path)
    finally:
        temporary.unlink(missing_ok=True)


def export_goal_clips(
    source_video: Path,
    candidates: list[Dict[str, Any]],
    output_dir: Path,
    mode: str,
    output_path: Path | None = None,
    progress_callback=None,
    cancel_check=None,
    process_callback=None,
) -> Dict[str, Any]:
    if mode not in {"separate", "merge"}:
        raise ValueError("INVALID_EXPORT_MODE")
    started = time.perf_counter()
    output_dir.mkdir(parents=True, exist_ok=True)
    files: list[Path] = []
    created_files: list[Path] = []
    codecs = video_codecs()
    try:
        for index, candidate in enumerate(candidates, 1):
            path = available_output_path(output_dir / clip_file_name(index, candidate))
            codec = run_encoded_ffmpeg(
                lambda codec: build_clip_command(
                    source_video,
                    int(candidate["review_start_ms"]),
                    int(candidate["review_end_ms"]),
                    path,
                    codec,
                ),
                path,
                codecs,
                cancel_check=cancel_check,
                process_callback=process_callback,
            )
            # Later clips start with the encoder that worked, so they skip the
            # failed hardware attempts and share one codec for the merge copy.
            codecs = [codec, *(other for other in codecs if other != codec)]
            created_files.append(path)
            files.append(path)
            if progress_callback:
                progress_callback("export_clips", index / max(1, len(candidates)))
        merged_path = None
        if mode == "merge" and files:
            merged_path = output_path or available_output_path(output_dir / "highlights.mp4")
            merged_existed = merged_path.exists()
            concat_file = output_dir / "concat.txt"
            concat_file.write_text(
                "".join(concat_manifest_entry(path) for path in files),
                encoding="utf-8",
            )
            merge_command = [
                resolve_media_tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
                "-f", "concat", "-safe", "0", "-i", str(concat_file),
                "-c", "copy", str(merged_path),
            ]
            try:
                run_atomic_ffmpeg(
                    merge_command,
                    merged_path,
                    cancel_check=cancel_check,
                    process_callback=process_callback,
                )
            except (OSError, subprocess.CalledProcessError):
                # Separate clips use a common encoder, so stream-copy is the
                # fast path. Re-encode only when timestamps/codecs prevent a
                # valid concat output.
                run_encoded_ffmpeg(
                    lambda codec: [
                        resolve_media_tool("ffmpeg"), "-y", "-hide_banner", "-loglevel", "error",
                        "-f", "concat", "-safe", "0", "-i", str(concat_file),
                        *video_codec_options(codec),
                        "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart",
                        str(merged_path),
                    ],
                    merged_path,
                    codecs,
                    cancel_check=cancel_check,
                    process_callback=process_callback,
                )
            if not merged_existed:
                created_files.append(merged_path)
            if progress_callback:
                progress_callback("merge_clips", 0.98)
        else:
            merged_path = None
    except Exception:
        for path in created_files:
            path.unlink(missing_ok=True)
        raise
    export_files = [merged_path] if merged_path else files
    return {
        "files": [str(path) for path in export_files],
        "clip_files": [str(path) for path in files],
        "duration_ms": sum(int(candidate["review_end_ms"]) - int(candidate["review_start_ms"]) for candidate in candidates),
        "processing_ms": round((time.perf_counter() - started) * 1000),
    }
