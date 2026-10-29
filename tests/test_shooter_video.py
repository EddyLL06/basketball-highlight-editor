"""Small generated videos exercise real decoding without checking in footage."""

import pytest

from basketball_highlight.attribution_video import (
    AnalysisConfig,
    ShooterAttributionPipeline,
    inspect_video,
    iter_video_frames,
)
from basketball_highlight.player_detection import Detection
from basketball_highlight.shooter_attribution import ScoringEvent


@pytest.fixture
def tiny_video(tmp_path):
    cv2 = pytest.importorskip("cv2")
    np = pytest.importorskip("numpy")
    path = tmp_path / "fixture.avi"
    writer = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"MJPG"), 10, (320, 240))
    if not writer.isOpened():
        pytest.skip("MJPG encoder unavailable")
    for i in range(50):
        writer.write(np.full((240, 320, 3), i * 4, dtype=np.uint8))
    writer.release()
    return path


def test_real_decoder_timestamp_alignment_and_bounded_sampling(tiny_video):
    info = inspect_video(tiny_video)
    frames = list(iter_video_frames(tiny_video, 1.2, 2, 5, info))
    assert [i for i, _, _ in frames] == [12, 14, 16, 18]
    assert [t for _, t, _ in frames] == pytest.approx([1.2, 1.4, 1.6, 1.8])
    assert frames[0][2].shape == (240, 320, 3)


def test_real_video_pipeline_reuses_overlaps_and_expands_without_reinference(
    tiny_video,
):
    class EmptyDetector:
        def __init__(self):
            self.calls = []

        def detect(self, frame, timestamp):
            self.calls.append(timestamp)
            return []

    players, balls = EmptyDetector(), EmptyDetector()
    pipeline = ShooterAttributionPipeline(
        players,
        balls,
        config=AnalysisConfig(window_before=1, max_window_before=2, sample_fps=5),
    )
    output = pipeline.analyze(
        tiny_video, [ScoringEvent("first", 3), ScoringEvent("second", 3.5)]
    )
    assert len(output["sessions"]) == 1
    assert len(players.calls) == len(set(players.calls))
    assert min(players.calls) >= 2
    assert all(r["reason"] == "ball_missing_at_event" for r in output["results"])


def test_real_video_end_to_end_with_injected_deterministic_detections(tiny_video):
    # Model-free inference fixture; decoding, tracking, release and JSON are real.
    centers = [(45, 110)] * 4 + [
        (48, 80),
        (75, 45),
        (100, 25),
        (125, 20),
        (150, 25),
        (175, 35),
        (200, 45),
        (225, 60),
        (250, 80),
    ]

    class Detector:
        def __init__(self, is_ball):
            self.is_ball = is_ball

        def detect(self, frame, timestamp):
            if not self.is_ball:
                return [Detection(timestamp, (20, 85, 65, 210), 0.95)]
            i = round(timestamp * 10)
            if i >= len(centers):
                return []
            x, y = centers[i]
            return [Detection(timestamp, (x - 4, y - 4, x + 4, y + 4), 0.95)]

    pipeline = ShooterAttributionPipeline(
        Detector(False), Detector(True), config=AnalysisConfig(sample_fps=10)
    )
    event = ScoringEvent("generated", 1.2, {"center_x": 250, "rim_y": 80, "width": 25})
    result = pipeline.analyze(tiny_video, [event])["results"][0]
    assert result["status"] == "attributed"
    assert result["shooter"]["release_time_ms"] < result["event_time_ms"]
