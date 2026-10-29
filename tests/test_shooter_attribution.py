"""Deterministic PR1 tests: no model weights, network, torch or GPU required."""

import json
import math
from dataclasses import replace

import pytest

from basketball_highlight.attribution_video import (
    AnalysisConfig,
    ShooterAttributionPipeline,
    VideoInfo,
    load_ball_records,
    merge_event_windows,
)
from basketball_highlight.ball_possession import (
    BallTrajectory,
    normalized_ball_distance,
    possession_strength,
    reconstruct_ball_trajectory,
)
from basketball_highlight.player_detection import (
    Detection,
    LocalYoloDetector,
    normalize_detection,
)
from basketball_highlight.player_tracking import PlayerTrack, PlayerTracker
from basketball_highlight.shooter_attribution import (
    ScoringEvent,
    ShooterAttributor,
    load_scoring_events,
)
from basketball_highlight.shot_release import ShotReleaseEstimator


def ball(t, x, y, confidence=0.95, size=12):
    return Detection(
        round(t, 6),
        (x - size / 2, y - size / 2, x + size / 2, y + size / 2),
        confidence,
    )


def player(t, x=100, confidence=0.95):
    return Detection(round(t, 6), (x, 200, x + 60, 400), confidence)


def shot_scene(*, extra_player=True):
    centers = [
        (150, 225),
        (150, 220),
        (150, 210),
        (150, 190),
        (155, 170),
        (190, 120),
        (230, 80),
        (270, 60),
        (310, 50),
        (350, 70),
        (390, 100),
        (430, 140),
        (450, 180),
    ]
    points = [ball(i / 10, x, y) for i, (x, y) in enumerate(centers)]
    tracks = [PlayerTrack(1, [player(p.timestamp) for p in points])]
    if extra_player:
        tracks.append(PlayerTrack(2, [player(p.timestamp, 700) for p in points]))
    return (
        BallTrajectory(points),
        tracks,
        ScoringEvent("shot", 1.2, {"center_x": 450, "rim_y": 180, "width": 40}),
    )


def attribute(trajectory, tracks, event, **kwargs):
    return ShooterAttributor(**kwargs).attribute(
        event, trajectory, tracks, tracking_scope="test-session", sample_fps=10
    )


def test_detection_transform_clips_and_scales_xyxy():
    d = normalize_detection(
        123.456,
        [-2, 10, 30, 50],
        0.9,
        scale=(2, 3),
        offset=(5, 7),
        frame_size=(50, 100),
    )
    assert d.bbox == (1, 37, 50, 100)
    assert d.timestamp == 123.456
    assert d.to_dict()["confidence"] == 0.9


@pytest.mark.parametrize(
    "bbox,confidence",
    [
        ((1, 2, 0, 3), 0.5),
        ((0, 0, 2, 0), 0.5),
        ((0, 0, math.nan, 4), 0.5),
        ((0, 0, 2, 3), 1.1),
    ],
)
def test_detection_rejects_invalid_geometry(bbox, confidence):
    with pytest.raises(ValueError):
        Detection(0, bbox, confidence)


def test_missing_model_is_checked_before_importing_inference(tmp_path):
    with pytest.raises(ValueError, match="MODEL_NOT_FOUND"):
        LocalYoloDetector(tmp_path / "missing.pt")


def test_player_tracking_brief_occlusion_low_confidence_rescue_and_expiry():
    tracker = PlayerTracker()
    tracker.update(0, [player(0)])
    tracker.update(0.1, [player(0.1, 105, 0.25)])
    tracker.update(0.2, [])
    tracker.update(0.3, [player(0.3, 115)])
    assert len(tracker.tracks) == 1
    assert len(tracker.tracks[0].observations) == 3
    tracker.update(1, [player(1, 115)])
    assert len(tracker.tracks) == 2
    assert tracker.tracks[1].track_id == 2


def test_low_confidence_detection_cannot_start_a_track():
    tracker = PlayerTracker()
    tracker.update(0, [player(0, confidence=0.2)])
    assert tracker.tracks == []


def test_tracker_supports_more_than_two_players_and_detection_order():
    tracker = PlayerTracker()
    tracker.update(0, [player(0, x) for x in (100, 300, 500, 700, 900, 1100)])
    tracker.update(0.1, [player(0.1, x + 5) for x in (1100, 900, 700, 500, 300, 100)])
    assert len(tracker.tracks) == 6
    assert all(len(t.observations) == 2 for t in tracker.tracks)


def test_ambiguous_track_associations_are_exposed():
    tracker = PlayerTracker()
    tracker.update(0, [player(0, 100), player(0, 110)])
    tracker.update(0.1, [player(0.1, 105), player(0.1, 106)])
    assert all(t.ambiguous_times for t in tracker.tracks)


def test_tracker_rejects_misaligned_or_repeated_timestamps():
    tracker = PlayerTracker()
    with pytest.raises(ValueError, match="TIME_MISMATCH"):
        tracker.update(0, [player(0.1)])
    tracker = PlayerTracker()
    tracker.update(0, [])
    with pytest.raises(ValueError, match="NOT_INCREASING"):
        tracker.update(0, [])


def test_scale_invariant_distance_and_ball_held_outside_box():
    b, p = ball(0, 180, 200), player(0)
    assert normalized_ball_distance(b, p) == pytest.approx(0.1)
    assert possession_strength(b, p) > 0
    scaled = lambda d: Detection(
        d.timestamp, tuple(v * 4 for v in d.bbox), d.confidence
    )
    assert normalized_ball_distance(scaled(b), scaled(p)) == normalized_ball_distance(
        b, p
    )
    assert possession_strength(ball(0, 140, 390), p) == 0


def test_uncontested_jump_shot_has_release_interval_and_heuristic_score():
    trajectory, tracks, event = shot_scene()
    result = attribute(trajectory, tracks, event)
    assert result["status"] == "attributed"
    assert result["shooter"]["track_id"] == 1
    assert result["shooter"]["release_time_ms"] == 450
    assert result["shooter"]["release_interval_ms"] == [400, 500]
    assert result["score_kind"] == "heuristic_not_calibrated"
    assert result["shooter"]["evidence"]["possession_observations"] >= 2
    assert "confidence" not in result["shooter"]


@pytest.mark.parametrize(
    "reason,change",
    [
        ("ball_trajectory_missing", "empty"),
        ("no_player_tracks", "no_players"),
        ("ambiguous_ball_path", "ambiguous_ball"),
        ("release_not_observed", "incomplete"),
        ("ambiguous_player_tracking", "switch"),
        ("score_below_threshold", "threshold"),
        ("multiple_plausible_shooters", "contested"),
        ("unreliable_player_track", "unreliable"),
    ],
)
def test_unknown_reasons(reason, change):
    trajectory, tracks, event = shot_scene()
    kwargs = {}
    if change == "empty":
        trajectory = BallTrajectory()
    elif change == "no_players":
        tracks = []
    elif change == "ambiguous_ball":
        trajectory.ambiguous = True
    elif change == "incomplete":
        trajectory.observations = trajectory.observations[6:]
    elif change == "switch":
        tracks[0].ambiguous_times = [0.4]
    elif change == "threshold":
        kwargs["min_score"] = 1
    elif change == "contested":
        tracks[1].observations = list(tracks[0].observations)
    elif change == "unreliable":
        tracks[0].observations = [
            replace(p, confidence=0.4) for p in tracks[0].observations
        ]
    result = attribute(trajectory, tracks, event, **kwargs)
    assert result["status"] == "unknown"
    assert result["shooter"] is None
    assert result["reason"] == reason


def test_single_possession_sample_does_not_establish_shooter():
    trajectory, tracks, event = shot_scene()
    trajectory.observations = trajectory.observations[4:]
    assert attribute(trajectory, tracks, event)["status"] == "unknown"


def test_upward_movement_without_possession_is_insufficient():
    trajectory, tracks, event = shot_scene()
    tracks[0].observations = [player(p.timestamp, 800) for p in trajectory.observations]
    assert attribute(trajectory, tracks, event)["reason"] == "release_not_observed"


def test_release_cannot_bridge_missing_player_observations():
    trajectory, tracks, event = shot_scene()
    tracks[0].observations = [
        p for p in tracks[0].observations if p.timestamp not in (0.4, 0.5)
    ]
    assert attribute(trajectory, tracks, event)["status"] == "unknown"


def test_ball_reconstruction_uses_event_anchor_and_rejects_false_object():
    trajectory, _, event = shot_scene()
    frames = [
        (p.timestamp, [ball(p.timestamp, 900, 900, 0.99), p])
        for p in trajectory.observations
    ]
    linked = reconstruct_ball_trajectory(
        frames, event.timestamp, (1000, 1000), rim=event.rim
    )
    assert linked.observations == trajectory.observations
    assert not linked.ambiguous


def test_reconstruction_records_short_occlusion_and_stops_at_long_gap():
    trajectory, _, event = shot_scene()
    frames = [
        (p.timestamp, [] if p.timestamp == 0.8 else [p])
        for p in trajectory.observations
    ]
    linked = reconstruct_ball_trajectory(
        frames, event.timestamp, (1000, 1000), rim=event.rim
    )
    assert linked.missing_times == [0.8]
    assert linked.observations[0].timestamp == 0
    frames = [(t, balls if t < 0.5 or t > 1 else []) for t, balls in frames]
    linked = reconstruct_ball_trajectory(
        frames, event.timestamp, (1000, 1000), rim=event.rim
    )
    assert linked.observations[0].timestamp == 1.1


def test_reconstruction_ambiguous_ball_paths_abstain():
    trajectory, _, event = shot_scene()
    frames = [
        (
            p.timestamp,
            [
                ball(p.timestamp, p.center[0] - 10, p.center[1]),
                ball(p.timestamp, p.center[0] + 10, p.center[1]),
            ],
        )
        for p in trajectory.observations
    ]
    assert reconstruct_ball_trajectory(
        frames, event.timestamp, (1000, 1000), rim=event.rim
    ).ambiguous


def test_ball_near_an_unrelated_hoop_is_not_the_event_ball():
    assert (
        reconstruct_ball_trajectory(
            [(1, [ball(1, 900, 900)])],
            1,
            (1000, 1000),
            rim={"center_x": 100, "rim_y": 100, "width": 30},
        ).reason
        == "ball_not_near_event_anchor"
    )


def test_pass_then_catch_and_shoot_credits_final_releaser():
    # The first player passes, the second catches and holds before shooting.
    centers = [(140, 220)] * 3 + [(220, 170), (300, 140), (380, 170)] + [(440, 220)] * 4
    centers += [
        (450, 170),
        (490, 110),
        (530, 70),
        (570, 50),
        (610, 65),
        (650, 100),
        (690, 150),
    ]
    points = [ball(i / 10, x, y) for i, (x, y) in enumerate(centers)]
    tracks = [
        PlayerTrack(1, [player(p.timestamp) for p in points]),
        PlayerTrack(2, [player(p.timestamp, 400) for p in points]),
    ]
    result = attribute(BallTrajectory(points), tracks, ScoringEvent("catch", 1.6))
    assert result["status"] == "attributed"
    assert result["shooter"]["track_id"] == 2


def test_layup_does_not_require_upward_only_trajectory():
    trajectory, tracks, event = shot_scene(extra_player=False)
    # A high close finish may travel sideways/downwards after release.
    for i, p in enumerate(trajectory.observations[5:], 5):
        trajectory.observations[i] = ball(
            p.timestamp, 200 + (i - 5) * 40, 150 + (i - 5) * 3
        )
    result = attribute(trajectory, tracks, event)
    assert result["status"] == "attributed"


def test_candidate_formats_units_and_manual_labels_preserved():
    payload = {
        "candidates": [
            {"id": "manual", "event_time_ms": 123456, "player_id": "roster-id"}
        ]
    }
    original = json.dumps(payload)
    assert load_scoring_events(payload)[0].timestamp == 123.456
    assert json.dumps(payload) == original
    assert (
        load_scoring_events({"results": [{"refined": [{"time": 12.3}]}]})[0].timestamp
        == 12.3
    )
    assert load_scoring_events({"event_ms": 1000})[0].timestamp == 1
    with pytest.raises(ValueError, match="CANDIDATE_INVALID"):
        load_scoring_events([{"time": math.nan}])
    with pytest.raises(ValueError, match="DUPLICATE"):
        load_scoring_events([{"id": "same", "time": 1}, {"id": "same", "time": 2}])


def test_cached_ball_coordinates_and_timestamp_offset(tmp_path):
    data = {
        "video": "proxy.mp4",
        "records": [
            {
                "time": 1,
                "detections": [
                    {"name": "ball", "xyxy": [10, 20, 30, 40], "confidence": 0.8}
                ],
            }
        ],
    }
    with pytest.raises(ValueError, match="EXPLICIT_SCALE"):
        load_ball_records(data, video=tmp_path / "source.mp4")
    records = load_ball_records(data, scale=2, time_offset=10)
    assert records[0][0] == 11
    assert records[0][1][0].bbox == (20, 40, 60, 80)


def test_windows_merge_without_decoding_unrelated_ranges():
    cfg = AnalysisConfig()
    groups = merge_event_windows(
        [ScoringEvent("a", 10), ScoringEvent("b", 12), ScoringEvent("c", 30)], cfg, 40
    )
    assert [(g["start"], g["end"]) for g in groups] == [(6, 12.15), (26, 30.15)]
    with pytest.raises(ValueError, match="OUTSIDE_VIDEO"):
        merge_event_windows([ScoringEvent("end", 40)], cfg, 40)


@pytest.mark.parametrize(
    "kwargs",
    [
        {"sample_fps": 0},
        {"sample_fps": math.inf},
        {"max_window_before": 2},
        {"min_score": 2},
        {"ball_max_gap": 0},
    ],
)
def test_invalid_configuration_fails_early(kwargs):
    with pytest.raises(ValueError):
        AnalysisConfig(**kwargs)


def test_pipeline_overlapping_windows_reuse_inference_and_preserve_event_order():
    trajectory, _, event = shot_scene()

    class FakeDetector:
        def __init__(self, is_ball):
            self.calls, self.is_ball = [], is_ball

        def detect(self, frame, timestamp):
            self.calls.append(timestamp)
            return (
                [trajectory.observations[frame]]
                if self.is_ball
                else [player(timestamp), player(timestamp, 700)]
            )

    def reader(video, start, end, sample_fps, info):
        for i, p in enumerate(trajectory.observations):
            if start <= p.timestamp < end:
                yield i, p.timestamp, i

    person, basketball = FakeDetector(False), FakeDetector(True)
    pipeline = ShooterAttributionPipeline(
        person,
        basketball,
        config=AnalysisConfig(sample_fps=10),
        video_reader=reader,
        video_inspector=lambda _: VideoInfo(1000, 1000, 10, 100),
    )
    result = pipeline.analyze(
        "fixture.mp4",
        [replace(event, candidate_id="b"), replace(event, candidate_id="a")],
    )
    assert len(person.calls) == len(trajectory.observations)
    assert result["performance"]["tracking_sessions"] == 1
    assert [r["candidate_id"] for r in result["results"]] == ["b", "a"]
    assert all(r["status"] == "attributed" for r in result["results"])
    assert (
        result["results"][0]["tracking_scope"] == result["results"][1]["tracking_scope"]
    )


def test_release_estimator_has_configurable_evidence_requirements():
    trajectory, tracks, event = shot_scene()
    assert not ShotReleaseEstimator(min_possession_observations=100).estimate(
        trajectory, tracks, event.timestamp
    )


def test_earlier_window_expansion_reuses_inference_and_finds_release():
    trajectory, _, event = shot_scene()
    points = [
        replace(p, timestamp=round(p.timestamp + 2, 6)) for p in trajectory.observations
    ]

    class Detector:
        def __init__(self, is_ball):
            self.calls, self.is_ball = [], is_ball

        def detect(self, frame, timestamp):
            self.calls.append(timestamp)
            return [points[frame]] if self.is_ball else [player(timestamp)]

    def reader(video, start, end, fps, info):
        for i, point in enumerate(points):
            if start <= point.timestamp < end:
                yield i, point.timestamp, i

    person = Detector(False)
    pipeline = ShooterAttributionPipeline(
        person,
        Detector(True),
        config=AnalysisConfig(sample_fps=10, window_before=0.5, max_window_before=2),
        video_reader=reader,
        video_inspector=lambda _: VideoInfo(1000, 1000, 10, 100),
    )
    result = pipeline.analyze("fixture", [replace(event, timestamp=3.2)])["results"][0]
    assert result["window_expanded"]
    assert result["status"] == "attributed"
    assert len(person.calls) == len(set(person.calls))


def test_cached_ball_observations_keep_source_timestamps():
    trajectory, _, event = shot_scene()

    class Person:
        def detect(self, frame, timestamp):
            return [player(timestamp)]

    def reader(video, start, end, fps, info):
        for i, point in enumerate(trajectory.observations):
            yield i, point.timestamp, i

    cached = [
        (p.timestamp + 0.01, [replace(p, timestamp=p.timestamp + 0.01)])
        for p in trajectory.observations
    ]
    pipeline = ShooterAttributionPipeline(
        Person(),
        None,
        config=AnalysisConfig(sample_fps=10),
        video_reader=reader,
        video_inspector=lambda _: VideoInfo(1000, 1000, 10, 100),
    )
    output = pipeline.analyze("fixture", [event], ball_records=cached)
    assert output["performance"]["reused_ball_frames"] == len(cached)
    assert (
        output["results"][0]["ball_trajectory"]["observations"][0]["timestamp"] == 0.01
    )


def test_rebound_and_putback_uses_the_final_release_not_the_first_attempt():
    first, _, _ = shot_scene()
    centers = [p.center for p in first.observations]
    centers += [(420, 210), (380, 240), (330, 230), (280, 220), (220, 220)]
    centers += [(150, 220)] * 3 + [(155, 170)]
    centers += [p.center for p in first.observations[5:]]
    points = [ball(i / 10, *center) for i, center in enumerate(centers)]
    track = PlayerTrack(1, [player(p.timestamp) for p in points])
    result = attribute(
        BallTrajectory(points), [track], ScoringEvent("putback", points[-1].timestamp)
    )
    assert result["status"] == "attributed"
    assert result["shooter"]["release_time_ms"] > 2000


def test_person_detector_resolves_metadata_and_retains_nearby_players(
    tmp_path, monkeypatch
):
    from types import SimpleNamespace

    import numpy as np

    from basketball_highlight import inference

    weights = tmp_path / "person.pt"
    weights.touch()
    boxes = [
        SimpleNamespace(cls=np.array([5]), conf=np.array([0.9]), xyxy=np.array([bbox]))
        for bbox in ((100, 100, 160, 300), (140, 100, 200, 300))
    ]
    model = SimpleNamespace(
        names={0: "ball", 5: "person"},
        predict=lambda *a, **k: [SimpleNamespace(boxes=boxes)],
    )
    monkeypatch.setattr(inference, "select_device", lambda *a: "cpu")
    monkeypatch.setattr(inference, "load_detector", lambda *a, **k: model)
    monkeypatch.setattr(inference, "current_device", lambda: "cpu")
    detector = LocalYoloDetector(weights)
    detections = detector.detect(np.zeros((400, 400, 3), dtype=np.uint8), 123.456)
    assert len(detections) == 2
    assert detections[0].timestamp == 123.456
    assert detector.device == "cpu"


def test_ball_only_weights_cannot_silently_become_a_person_detector(
    tmp_path, monkeypatch
):
    from types import SimpleNamespace

    from basketball_highlight import inference

    weights = tmp_path / "ball.pt"
    weights.touch()
    monkeypatch.setattr(inference, "select_device", lambda *a: "cpu")
    monkeypatch.setattr(
        inference,
        "load_detector",
        lambda *a, **k: SimpleNamespace(names={0: "ball", 1: "hoop"}),
    )
    monkeypatch.setattr(inference, "current_device", lambda: "cpu")
    with pytest.raises(ValueError, match="MODEL_LABEL_MISSING"):
        LocalYoloDetector(weights)


def test_confidence_cannot_override_the_event_anchor_geometry_gate():
    near = ball(1, 219, 100, confidence=0.1)
    outside = ball(1, 221, 100, confidence=0.99)
    trajectory = reconstruct_ball_trajectory(
        [(1, [outside, near])],
        1,
        (500, 500),
        rim={"center_x": 100, "rim_y": 100, "width": 40},
    )
    assert trajectory.observations == [near]
    assert not trajectory.ambiguous
