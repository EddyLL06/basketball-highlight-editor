import subprocess
import sys
from pathlib import Path


CHECK = Path(__file__).resolve().parents[1] / "scripts" / "check_open_source.py"


def test_demo_allowlist_and_real_violations(tmp_path):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    demo = tmp_path / "website/assets/recording-demo.mp4"
    demo.parent.mkdir(parents=True)
    demo.write_bytes(b"demo")
    subprocess.run(["git", "-C", str(tmp_path), "add", "."], check=True)

    def check():
        return subprocess.run(
            [sys.executable, str(CHECK), "--root", str(tmp_path)],
            capture_output=True,
            text=True,
            check=False,
        )

    assert check().returncode == 0

    # Even in a test file, an actual-looking local path must still be rejected.
    fixture = tmp_path / "packages/bhe_core/test/redact_test.dart"
    fixture.parent.mkdir(parents=True)
    fixture.write_text("/" + "Users" + "/real-person/private.txt", encoding="utf-8")
    other_video = demo.parent / "other.mp4"
    other_video.write_bytes(b"video")
    subprocess.run(["git", "-C", str(tmp_path), "add", "."], check=True)
    result = check()
    assert result.returncode == 1
    assert "machine-specific absolute path: packages/bhe_core/test/redact_test.dart" in result.stdout
    assert "binary/video/model artifact: website/assets/other.mp4" in result.stdout

    with demo.open("wb") as output:
        output.truncate(3 * 1024 * 1024 + 1)
    result = check()
    assert result.returncode == 1
    assert "binary/video/model artifact: website/assets/recording-demo.mp4" in result.stdout
