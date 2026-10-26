"""导出永远不能覆盖原视频：保存名不写扩展名、或经过符号链接时，补全后的最终路径也要检查。"""

import shutil
import subprocess
from pathlib import Path

import pytest

from engine.python.basketball_engine.adapters import export
from engine.python.basketball_engine.media_tools import resolve_media_tool
from engine.python.basketball_engine.protocol import ProtocolError
from engine.python.basketball_engine.service import EngineService
from engine.python.basketball_engine.storage import ProjectStore


def _ffmpeg_or_skip() -> str:
    ffmpeg = resolve_media_tool("ffmpeg")
    if not shutil.which(ffmpeg):
        pytest.skip("需要 ffmpeg")
    return ffmpeg


@pytest.mark.parametrize(
    ("case", "blocked"),
    [
        ("no_extension", True),  # 保存成 game，补全后是 game.mp4，正是原片
        ("link_to_source", True),  # alias.mp4 -> game.mp4
        ("link_to_extensionless_file", False),  # alias.mp4 -> game，补全不能把它变成 game.mp4
    ],
)
def test_export_never_overwrites_the_source_video(tmp_path: Path, monkeypatch, case: str, blocked: bool):
    ffmpeg = _ffmpeg_or_skip()
    source = tmp_path / "game.mp4"
    subprocess.run(
        [ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=10",
         "-t", "2", "-c:v", "mpeg4", "-pix_fmt", "yuv420p", str(source)],
        check=True,
    )
    if case == "no_extension":
        output = tmp_path / "game"
    else:
        output = tmp_path / "alias.mp4"
        target = source if case == "link_to_source" else tmp_path / "game"
        if case == "link_to_extensionless_file":
            target.write_bytes(b"unrelated")
        output.symlink_to(target)
    original = source.read_bytes()

    service = EngineService()
    project = tmp_path / "project"
    service.create_project({"name": case, "root_path": str(project)})
    info = service.inspect_video({"video_path": str(source)})
    video = ProjectStore(project).link_video({
        **info,
        "source_path": str(source),
        "source_size_bytes": source.stat().st_size,
        "source_mtime_ns": source.stat().st_mtime_ns,
        "source_fingerprint": service._source_fingerprint(source),
    })
    launches = []
    real_run = export.run_atomic_ffmpeg

    def record(*args, **kwargs):
        launches.append(args[1])
        return real_run(*args, **kwargs)

    monkeypatch.setattr(export, "video_codecs", lambda: ["mpeg4"])
    monkeypatch.setattr(export, "run_atomic_ffmpeg", record)
    request = {
        "project_root": str(project),
        "video_id": video["id"],
        "mode": "merge",
        "output_dir": str(tmp_path / "exports"),
        "output_path": str(output),
        "candidate_snapshot": [
            {"id": "c1", "video_id": video["id"], "event_time_ms": 500, "review_start_ms": 0, "review_end_ms": 700},
        ],
    }
    try:
        if blocked:
            with pytest.raises(ProtocolError) as error:
                service._execute_export(request)
            assert error.value.code == "EXPORT_SOURCE_CONFLICT"
            assert launches == []
        else:
            service._execute_export(request)
            assert output.is_file() and not output.is_symlink()
    finally:
        service.shutdown()

    assert source.read_bytes() == original
