import sys
from pathlib import Path

import pytest

from scripts.check_runtime import _check_binary, _check_numpy_bridge


def _write_tool(path: Path, version: str) -> None:
    """写一个可执行的假工具,输出指定的 version 字符串。

    POSIX 用 shell 脚本;Windows 用 .cmd 批处理(shell 脚本在
    Windows 上无法直接执行,subprocess 会报 WinError 193)。
    """
    if sys.platform == "win32":
        cmd_path = path.with_suffix(".cmd") if path.suffix == "" else path
        cmd_path.write_text(
            f"@echo off\necho {version}\n", encoding="utf-8"
        )
        cmd_path.chmod(0o755)
    else:
        path.write_text(f"#!/bin/sh\nprintf '%s\\n' '{version}'\n", encoding="utf-8")
        path.chmod(0o755)


def test_check_binary_rejects_ffmpeg_disguised_as_ffprobe(tmp_path: Path):
    tool = tmp_path / "ffprobe"
    if sys.platform == "win32":
        tool = tool.with_suffix(".cmd")
    _write_tool(tool, "ffmpeg version 8.0")

    ok, detail = _check_binary(str(tool), "ffprobe")

    assert not ok
    assert "not ffprobe" in detail


def test_check_binary_accepts_expected_tool(tmp_path: Path):
    tool = tmp_path / "ffprobe"
    if sys.platform == "win32":
        tool = tool.with_suffix(".cmd")
    _write_tool(tool, "ffprobe version 8.0")

    ok, detail = _check_binary(str(tool), "ffprobe")

    assert ok
    assert detail == str(tool.resolve())


def test_missing_detector_check_fails_runtime_validation(tmp_path, monkeypatch, capsys):
    import json
    from types import SimpleNamespace
    from scripts import check_runtime

    for name in ['engine/python/basketball_engine', 'src/basketball_highlight', 'scripts',
                 'models', 'docs/architecture']:
        (tmp_path / name).mkdir(parents=True)
    (tmp_path / 'models/bball_model.pt').write_bytes(b'model')
    (tmp_path / 'docs/architecture/SQLITE_SCHEMA_V1.sql').write_text('schema')
    for name in check_runtime.REQUIRED_SCRIPTS:
        if name != 'check_detector.py':
            (tmp_path / 'scripts' / name).write_text('script')
    monkeypatch.setattr(check_runtime, '_parse_args', lambda: SimpleNamespace(
        root=tmp_path, model=None, python_path=sys.executable, ffmpeg='ffmpeg', ffprobe='ffprobe', json=True))
    monkeypatch.setattr(check_runtime, '_check_imports', lambda _: (True, 'ok'))
    monkeypatch.setattr(check_runtime, '_check_numpy_bridge', lambda _: (True, 'ok'))
    monkeypatch.setattr(check_runtime, '_check_binary', lambda *args: (True, 'ok'))
    monkeypatch.setattr(check_runtime, '_acceleration_report', lambda *args: {})
    assert check_runtime.main() == 1
    result = json.loads(capsys.readouterr().out)
    assert result['checks']['scripts'] == {'ok': False, 'missing': ['check_detector.py']}
    (tmp_path / 'scripts/check_detector.py').write_text('script')
    assert check_runtime.main() == 0
    assert json.loads(capsys.readouterr().out)['ok'] is True


@pytest.mark.skipif(sys.platform == "win32", reason="用 POSIX shell 脚本伪造解释器")
def test_numpy_bridge_fails_when_torch_cannot_reach_numpy(tmp_path: Path):
    """numpy 和 torch 都能 import，但桥接失败时必须判 FAILED。

    现场对应：torch<=2.2 按 NumPy 1.x ABI 编译，运行时装了 numpy>=2，
    两个 import 都正常，只有 torch.from_numpy 抛 "Numpy is not available"。
    """
    fake = tmp_path / "python"
    fake.write_text(
        "#!/bin/sh\n"
        "printf '%s\\n' 'A module that was compiled using NumPy 1.x cannot be run in NumPy 2.4.6' >&2\n"
        "printf '%s\\n' 'RuntimeError: Numpy is not available' >&2\n"
        "exit 1\n",
        encoding="utf-8",
    )
    fake.chmod(0o755)

    ok, detail = _check_numpy_bridge(str(fake))

    assert not ok
    assert "Numpy is not available" in detail


@pytest.mark.skipif(sys.platform == "win32", reason="用 POSIX shell 脚本伪造解释器")
def test_numpy_bridge_reports_versions_on_success(tmp_path: Path):
    fake = tmp_path / "python"
    fake.write_text(
        "#!/bin/sh\n"
        "printf '%s\\n' 'numpy=1.26.4 torch=2.2.0 ok=(1,)'\n"
        "exit 0\n",
        encoding="utf-8",
    )
    fake.chmod(0o755)

    ok, detail = _check_numpy_bridge(str(fake))

    assert ok
    assert "numpy=1.26.4" in detail

