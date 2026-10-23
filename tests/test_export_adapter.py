import io
from pathlib import Path
import subprocess

import pytest

from engine.python.basketball_engine.adapters.analysis import PipelineCancelled
from engine.python.basketball_engine.adapters.export import build_clip_command, run_atomic_ffmpeg
from engine.python.basketball_engine.adapters import export


def test_libx264_clip_command_contains_one_video_codec():
    command = build_clip_command(Path("source.mp4"), 0, 1000, Path("out.mp4"), "libx264")
    assert command.count("-c:v") == 1
    assert command[command.index("-c:v") + 1] == "libx264"


def test_clip_file_name_appends_a_filesystem_safe_player_name():
    candidate = {"event_time_ms": 12345}
    assert export.clip_file_name(1, candidate) == "goal_001_12.35s.mp4"
    assert export.clip_file_name(2, {**candidate, "player_name": "科比"}) == "goal_002_12.35s_科比.mp4"
    assert export.clip_file_name(3, {**candidate, "player_name": ' A/B:C*? '}) == "goal_003_12.35s_A_B_C.mp4"
    assert export.clip_file_name(4, {**candidate, "player_name": "..."}) == "goal_004_12.35s.mp4"


def test_clip_command_maps_only_the_first_audio_stream():
    command = build_clip_command(Path("source.mov"), 0, 1000, Path("out.mp4"), "libx264")
    maps = [command[index + 1] for index, item in enumerate(command) if item == "-map"]
    assert maps == ["0:v:0?", "0:a:0?"]


def test_clip_command_rejects_invalid_range():
    with pytest.raises(ValueError, match="INVALID_CLIP_RANGE"):
        build_clip_command(Path("source.mp4"), 1000, 1000, Path("out.mp4"))


@pytest.mark.parametrize("mode", ["separate", "merge"])
def test_export_without_h264_encoders_falls_back_for_clips_and_merge(tmp_path, monkeypatch, mode):
    monkeypatch.setattr(export.platform, "system", lambda: "Linux")
    attempts = []

    def fake_ffmpeg(command, output_path, **kwargs):
        if "-c:v" not in command:
            attempts.append("copy")
            raise subprocess.CalledProcessError(1, command)
        codec = command[command.index("-c:v") + 1]
        attempts.append(codec)
        if codec != "mpeg4":
            raise subprocess.CalledProcessError(1, command)
        assert command[command.index("-q:v") + 1] == "2"
        output_path.write_bytes(b"video")

    monkeypatch.setattr(export, "run_atomic_ffmpeg", fake_ffmpeg)
    result = export.export_goal_clips(
        tmp_path / "source.mp4",
        [{"event_time_ms": 500, "review_start_ms": 0, "review_end_ms": 1000}],
        tmp_path / "export", mode,
    )
    expected = ["libx264", "libopenh264", "mpeg4"]
    if mode == "merge":
        expected += ["copy", "mpeg4"]
    assert attempts == expected
    assert all(Path(path).is_file() for path in result["files"])


def test_codec_order_per_platform(monkeypatch):
    software = ["libx264", "libopenh264", "mpeg4"]
    monkeypatch.setattr(export.platform, "system", lambda: "Darwin")
    assert export.video_codecs() == ["h264_videotoolbox", *software]
    monkeypatch.setattr(export.platform, "system", lambda: "Windows")
    assert export.video_codecs() == ["h264_nvenc", "h264_qsv", "h264_amf", "h264_mf", *software]


def test_hardware_encoders_get_a_bitrate():
    options = export.video_codec_options("h264_nvenc")
    assert options[options.index("-b:v") + 1] == "16M"


@pytest.mark.parametrize("mode", ["separate", "merge"])
def test_windows_tries_gpu_encoders_and_keeps_the_one_that_works(tmp_path, monkeypatch, mode):
    monkeypatch.setattr(export.platform, "system", lambda: "Windows")
    attempts = []

    def fake_ffmpeg(command, output_path, **kwargs):
        if "-c:v" not in command:
            attempts.append("copy")
            raise subprocess.CalledProcessError(1, command)
        codec = command[command.index("-c:v") + 1]
        attempts.append(codec)
        if codec in {"h264_nvenc", "h264_qsv"}:
            raise subprocess.CalledProcessError(1, command)
        output_path.write_bytes(b"video")

    monkeypatch.setattr(export, "run_atomic_ffmpeg", fake_ffmpeg)
    export.export_goal_clips(
        tmp_path / "source.mp4",
        [
            {"event_time_ms": 500, "review_start_ms": 0, "review_end_ms": 1000},
            {"event_time_ms": 2500, "review_start_ms": 2000, "review_end_ms": 3000},
        ],
        tmp_path / "export", mode,
    )
    expected = ["h264_nvenc", "h264_qsv", "h264_amf", "h264_amf"]
    if mode == "merge":
        expected += ["copy", "h264_amf"]
    assert attempts == expected


def test_export_does_not_retry_cancelled_encoding(tmp_path, monkeypatch):
    attempts = []

    def cancel(command, output_path, **kwargs):
        attempts.append(command)
        raise PipelineCancelled("JOB_CANCELLED")

    monkeypatch.setattr(export, "run_atomic_ffmpeg", cancel)
    with pytest.raises(PipelineCancelled):
        export.export_goal_clips(
            tmp_path / "source.mp4",
            [{"event_time_ms": 500, "review_start_ms": 0, "review_end_ms": 1000}],
            tmp_path / "export", "separate",
        )
    assert len(attempts) == 1


def test_export_surfaces_error_when_all_encoders_fail(tmp_path, monkeypatch):
    monkeypatch.setattr(export.platform, "system", lambda: "Linux")
    attempts = []

    def fail(command, output_path, **kwargs):
        attempts.append(command[command.index("-c:v") + 1])
        raise subprocess.CalledProcessError(1, command)

    monkeypatch.setattr(export, "run_atomic_ffmpeg", fail)
    with pytest.raises(subprocess.CalledProcessError):
        export.export_goal_clips(
            tmp_path / "source.mp4",
            [{"event_time_ms": 500, "review_start_ms": 0, "review_end_ms": 1000}],
            tmp_path / "export", "separate",
        )
    assert attempts == ["libx264", "libopenh264", "mpeg4"]
    assert not list((tmp_path / "export").glob("*.mp4"))


def test_run_atomic_ffmpeg_validates_and_renames_output(tmp_path: Path, monkeypatch):
    output = tmp_path / "clip.mp4"

    class FakeProcess:
        returncode = 0

        def __init__(self, command, **_kwargs):
            Path(command[-1]).write_bytes(b"video")

        def poll(self):
            return self.returncode

    def fake_run(command, **_kwargs):
        return type("Completed", (), {"stdout": "1.25\n"})()

    monkeypatch.setattr(
        "engine.python.basketball_engine.adapters.export.subprocess.Popen",
        FakeProcess,
    )
    monkeypatch.setattr(
        "engine.python.basketball_engine.adapters.export.subprocess.run",
        fake_run,
    )
    run_atomic_ffmpeg(["ffmpeg", "-y", "-i", "source.mp4", str(output)], output)
    assert output.read_bytes() == b"video"
    assert not list(tmp_path.glob("*.part*"))


def test_run_atomic_ffmpeg_removes_partial_output_on_failure(tmp_path: Path, monkeypatch):
    output = tmp_path / "clip.mp4"

    class FakeProcess:
        returncode = 1

        def __init__(self, command, **_kwargs):
            Path(command[-1]).write_bytes(b"partial")

        def poll(self):
            return self.returncode

    import subprocess
    monkeypatch.setattr(
        "engine.python.basketball_engine.adapters.export.subprocess.Popen",
        FakeProcess,
    )
    with pytest.raises(subprocess.CalledProcessError):
        run_atomic_ffmpeg(["ffmpeg", "-y", str(output)], output)
    assert not output.exists()
    assert not list(tmp_path.glob("*.part*"))


def test_run_atomic_ffmpeg_keeps_stderr_tail_in_error(tmp_path: Path, monkeypatch):
    output = tmp_path / "clip.mp4"
    stderr_text = (
        "[aist#0:2/none @ 0x1] Decoding requested, but no decoder found for: none\n"
        "Error opening output files: Invalid argument\n"
    )

    class FakeProcess:
        returncode = 234

        def __init__(self, command, **_kwargs):
            Path(command[-1]).write_bytes(b"partial")
            self.stderr = io.StringIO(stderr_text)

        def poll(self):
            return self.returncode

    monkeypatch.setattr(
        "engine.python.basketball_engine.adapters.export.subprocess.Popen",
        FakeProcess,
    )
    with pytest.raises(subprocess.CalledProcessError) as error:
        run_atomic_ffmpeg(["ffmpeg", "-y", str(output)], output)
    message = str(error.value)
    assert "exit status 234" in message
    assert "no decoder found for: none" in message
    assert "Invalid argument" in message
    assert not output.exists()
    assert not list(tmp_path.glob("*.part*"))


def test_run_atomic_ffmpeg_stops_running_process_when_cancelled(tmp_path: Path, monkeypatch):
    output = tmp_path / "clip.mp4"
    processes = []

    class FakeProcess:
        returncode = None

        def __init__(self, command, **_kwargs):
            self.command = command

        def poll(self):
            return self.returncode

    def fake_popen(command, **kwargs):
        process = FakeProcess(command, **kwargs)
        processes.append(process)
        return process

    def fake_terminate(process):
        process.returncode = -15

    callbacks = []
    monkeypatch.setattr(
        "engine.python.basketball_engine.adapters.export.subprocess.Popen",
        fake_popen,
    )
    monkeypatch.setattr(
        "engine.python.basketball_engine.adapters.export.terminate_process",
        fake_terminate,
    )

    with pytest.raises(PipelineCancelled, match="JOB_CANCELLED"):
        run_atomic_ffmpeg(
            ["ffmpeg", "-y", str(output)],
            output,
            cancel_check=lambda: True,
            process_callback=callbacks.append,
        )

    assert processes[0].returncode == -15
    assert callbacks == [processes[0], None]
    assert not output.exists()
