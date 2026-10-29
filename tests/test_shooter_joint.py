"""Model-free contracts for global matching, observation replay and joint evidence."""

import random
from dataclasses import asdict
from itertools import permutations

import numpy as np
import pytest

from basketball_highlight.attribution_video import (
    AnalysisConfig,
    ShooterAttributionPipeline,
    VideoInfo,
)
from basketball_highlight.ball_possession import BallTrajectory
from basketball_highlight.joint_attribution import (
    JointShooterAttributor,
    ball_path_hypotheses,
)
from basketball_highlight.player_detection import (
    Detection,
    PlayerGuidedBallDetector,
    torso_signature,
)
from basketball_highlight.player_tracking import (
    PlayerTrack,
    PlayerTracker,
    appearance_distance,
    minimum_cost_assignment,
    suppress_player_duplicates,
)
from basketball_highlight.shooter_attribution import ScoringEvent
from basketball_highlight.shooter_evaluation import (
    build_spatial_references,
    evaluate_spatial_references,
)
from basketball_highlight.shooter_observations import (
    ObservationArchive,
    video_fingerprint,
)
from basketball_highlight.shot_release import ShotReleaseEstimator
from basketball_highlight.trajectory_gaps import top_boundary_bridge


def ball(t, x, y, confidence=0.95):
    return Detection(t, (x - 6, y - 6, x + 6, y + 6), confidence)


def player(t):
    return Detection(t, (100, 200, 160, 400), 0.95)


def shot_scene():
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
    tracks = [
        PlayerTrack(1, [player(p.timestamp) for p in points]),
        PlayerTrack(
            2, [Detection(p.timestamp, (700, 200, 760, 400), 0.95) for p in points]
        ),
    ]
    return (
        BallTrajectory(points),
        tracks,
        ScoringEvent("fixture", 1.2, {"center_x": 450, "rim_y": 180, "width": 40}),
    )


@pytest.mark.parametrize("n,m", [(1, 3), (3, 1), (2, 2), (3, 4), (4, 3), (4, 4)])
def test_global_assignment_matches_brute_force_optimum(n, m):
    rng = random.Random(912 + n * 10 + m)
    for _ in range(10):
        costs = [[rng.uniform(-2, 4) for _ in range(m)] for _ in range(n)]
        chosen = minimum_cost_assignment(costs)
        actual = sum(costs[i][j] for i, j in chosen)
        if n <= m:
            expected = min(
                sum(costs[i][j] for i, j in enumerate(cols))
                for cols in permutations(range(m), n)
            )
        else:
            expected = min(
                sum(costs[i][j] for j, i in enumerate(rows))
                for rows in permutations(range(n), m)
            )
        assert actual == pytest.approx(expected)
        assert len({i for i, _ in chosen}) == min(n, m)
        assert len({j for _, j in chosen}) == min(n, m)


def test_global_assignment_avoids_greedy_trap_and_has_deterministic_ties():
    assert minimum_cost_assignment([[0.1, 0.2], [0.11, 10]]) == [(0, 1), (1, 0)]
    assert minimum_cost_assignment([[0, 0], [0, 0]]) == [(0, 0), (1, 1)]
    assert minimum_cost_assignment([]) == []


def test_clothing_evidence_preserves_tracks_through_short_occlusion():
    black, white = (1.0, 0.0), (0.0, 1.0)

    def person(t, x, signature):
        return Detection(t, (x, 100, x + 50, 300), 0.95, signature)

    tracker = PlayerTracker()
    tracker.update(0, [person(0, 100, black), person(0, 220, white)])
    tracker.update(0.1, [person(0.1, 160, white)])
    tracker.update(0.2, [person(0.2, 110, white), person(0.2, 210, black)])
    assert len(tracker.tracks) == 2
    assert tracker.tracks[0].observations[-1].bbox[0] == 210
    assert tracker.tracks[1].observations[-1].bbox[0] == 110
    assert not tracker.tracks[0].ambiguous_times


def test_torso_features_keep_black_white_distinct_and_roundtrip():
    black = np.zeros((100, 100, 3), dtype=np.uint8)
    white = np.full_like(black, 255)
    a, b = (
        torso_signature(black, (10, 10, 90, 90)),
        torso_signature(white, (10, 10, 90, 90)),
    )
    assert sum(a) == pytest.approx(1)
    assert appearance_distance(a, b) > 0.9
    d = Detection(1, (1, 2, 3, 4), 0.9, a)
    assert Detection.from_dict(d.to_dict()) == d


def test_guided_ball_regions_are_bounded_and_cover_upper_body():
    class RegionDetector:
        device = "cpu"

        def detect_regions(self, frame, timestamp, crops):
            return crops

    detector = PlayerGuidedBallDetector(RegionDetector())
    crops = detector.detect_with_players(
        np.zeros((500, 800, 3), np.uint8), 0, [player(0)]
    )
    assert crops[0] == (0, 0, 800, 500)
    assert len(crops) == 2
    x, y, w, h = crops[1]
    assert 0 <= x < x + w <= 800 and 0 <= y < y + h <= 500
    assert y < 200 and y + h > 240


def test_duplicate_suppression_keeps_overlapping_different_players():
    white, black = (1.0, 0.0), (0.0, 1.0)
    a = Detection(0, (100, 100, 170, 300), 0.9, white)
    duplicate = Detection(0, (102, 100, 165, 300), 0.6, white)
    defender = Detection(0, (103, 100, 173, 300), 0.85, black)
    assert suppress_player_duplicates([duplicate, defender, a]) == [a, defender]
    tracker = PlayerTracker(suppress_duplicates=True)
    tracker.update(0, [duplicate, defender, a])
    assert len(tracker.tracks) == 2
    same_clothes_overlap = Detection(0, (111, 100, 181, 300), 0.8, white)
    assert suppress_player_duplicates([a, same_clothes_overlap]) == [
        a,
        same_clothes_overlap,
    ]


def test_contextual_possession_excludes_nearby_defender():
    trajectory, tracks, event = shot_scene()
    tracks[1].observations = [
        Detection(p.timestamp, (150, 245, 210, 445), 0.95)
        for p in trajectory.observations
    ]
    legacy = ShotReleaseEstimator(tolerate_missing_possession=True)
    contextual = ShotReleaseEstimator(
        tolerate_missing_possession=True, contextual_possession=True
    )
    assert {
        h.track_id
        for h in legacy.estimate(trajectory, tracks, event.timestamp, sample_fps=10)
    } == {1, 2}
    assert {
        h.track_id
        for h in contextual.estimate(trajectory, tracks, event.timestamp, sample_fps=10)
    } == {1}


def test_contextual_ambiguity_must_intersect_observed_release_support():
    trajectory, tracks, event = shot_scene()
    frames = [(p.timestamp, [p]) for p in trajectory.observations]
    tracks[0].ambiguous_times = [-0.05]
    result, _ = JointShooterAttributor(contextual=True).attribute(
        event, frames, tracks, (1000, 1000), tracking_scope="test", sample_fps=10
    )
    assert result["status"] == "attributed"
    tracks[0].ambiguous_times = [0.3]
    result, _ = JointShooterAttributor(contextual=True).attribute(
        event, frames, tracks, (1000, 1000), tracking_scope="test", sample_fps=10
    )
    assert result["reason"] == "ambiguous_player_tracking"


def test_contextual_catch_inside_initial_flight_window_vetoes_passer():
    trajectory, tracks, event = shot_scene()
    centers = [(p.center) for p in trajectory.observations[:5]] + [
        (190, 120),
        (220, 120),
        (222, 118),
        (225, 115),
        (255, 90),
        (310, 70),
        (390, 100),
        (450, 180),
    ]
    trajectory = BallTrajectory(
        [ball(i / 10, x, y) for i, (x, y) in enumerate(centers)]
    )
    tracks[1].observations = [
        Detection(p.timestamp, (210, 100, 270, 300), 0.95)
        for p in trajectory.observations
    ]
    legacy = ShotReleaseEstimator(tolerate_missing_possession=True)
    contextual = ShotReleaseEstimator(
        tolerate_missing_possession=True, contextual_possession=True
    )
    assert 1 in {
        h.track_id
        for h in legacy.estimate(trajectory, tracks, event.timestamp, sample_fps=10)
    }
    assert {
        h.track_id
        for h in contextual.estimate(trajectory, tracks, event.timestamp, sample_fps=10)
    } == {2}


@pytest.mark.parametrize(
    "ambiguous_time,accepted", [(0.1, True), (0.4, False), (0.7, False), (0.8, True)]
)
def test_v4_revalidates_local_identity_but_retains_release_ambiguity(
    ambiguous_time, accepted
):
    trajectory, tracks, event = shot_scene()
    tracks[0].ambiguous_times = [ambiguous_time]
    frames = [(p.timestamp, [p]) for p in trajectory.observations]
    result, _ = JointShooterAttributor(contextual=True, refined=True).attribute(
        event, frames, tracks, (1000, 1000), tracking_scope="test", sample_fps=10
    )
    assert (result["status"] == "attributed") is accepted
    if accepted:
        assert result["shooter"]["evidence"]["release_identity_revalidated"]
        if ambiguous_time == 0.8:
            assert result["shooter"]["evidence"][
                "flight_evidence_end_seconds"
            ] == pytest.approx(0.7)
    else:
        assert result["reason"] == "ambiguous_player_tracking"


@pytest.mark.parametrize("stationary", [False, True])
def test_v4_compact_finish_requires_real_ball_motion(stationary):
    trajectory, tracks, event = shot_scene()
    centers = (
        [(p.center) for p in trajectory.observations[:5]]
        + [(155, 170 if stationary else y) for y in (150, 140, 135, 140)]
        + [(350, 70), (390, 100), (430, 140), (450, 180)]
    )
    trajectory = BallTrajectory(
        [ball(i / 10, x, y) for i, (x, y) in enumerate(centers)]
    )
    tracks[0].observations = [
        Detection(
            p.timestamp,
            (
                100,
                200 + max(0, p.timestamp - 0.4) * 250,
                160,
                400 + max(0, p.timestamp - 0.4) * 250,
            ),
            0.95,
        )
        for p in trajectory.observations
    ]
    estimator = ShotReleaseEstimator(
        tolerate_missing_possession=True,
        contextual_possession=True,
        refine_release=True,
    )
    found = estimator.estimate(trajectory, tracks, event.timestamp, sample_fps=10)
    assert bool(found) is not stationary
    if found:
        assert found[0].evidence["compact_release"]


@pytest.mark.parametrize("upward", [True, False])
def test_v4_low_release_needs_sustained_upward_flight(upward):
    trajectory, tracks, event = shot_scene()
    centers = (
        [(150, 320), (150, 315), (150, 310)]
        + (
            [(215, 285), (260, 250), (310, 210)]
            if upward
            else [(215, 340), (260, 375), (310, 390)]
        )
        + [(370, 180), (410, 160), (450, 180)]
    )
    trajectory = BallTrajectory(
        [ball(i / 10, x, y) for i, (x, y) in enumerate(centers)]
    )
    for track in tracks:
        track.observations = [
            Detection(p.timestamp, track.observations[0].bbox, 0.95)
            for p in trajectory.observations
        ]
    estimator = ShotReleaseEstimator(
        tolerate_missing_possession=True,
        contextual_possession=True,
        refine_release=True,
    )
    found = estimator.estimate(trajectory, tracks, event.timestamp, sample_fps=10)
    assert bool(found) is upward
    if found:
        assert found[0].evidence["upward_underhand_release"]


def test_v4_refinement_requires_context_and_three_flight_observations():
    with pytest.raises(ValueError, match="REQUIRES_CONTEXT"):
        ShotReleaseEstimator(refine_release=True)
    with pytest.raises(ValueError, match="THREE_FLIGHT"):
        ShotReleaseEstimator(
            refine_release=True, contextual_possession=True, min_flight_observations=2
        )


def boundary_arc(vertical_offset=0):
    points = [
        ball(i / 10, 100 + 50 * i, 800 * (i / 10 - 0.6) ** 2 - 70 + vertical_offset)
        for i in range(13)
    ]
    frames = {
        p.timestamp: [p] if p.timestamp < 0.4 or p.timestamp > 0.8 else []
        for p in points
    }
    return points, frames


def test_top_boundary_bridge_requires_observations_and_records_real_gap():
    points, frames = boundary_arc()
    evidence = top_boundary_bridge(points[3], points[9:12], frames, (1000, 600))
    assert evidence["duration_seconds"] == pytest.approx(0.6)
    assert evidence["support_observations"] == 6
    assert evidence["synthetic_observations"] == 0
    paths = ball_path_hypotheses(
        list(frames.items()),
        1.2,
        (1920, 1080),
        rim={"center_x": 700, "rim_y": 218, "width": 20},
        allow_out_of_frame=True,
    )
    assert any(path.observations[0].timestamp <= 0.3 for path, _ in paths)
    for path, _ in paths:
        assert all(p in points for p in path.observations)
    assert any(path.observed_gaps for path, _ in paths)


@pytest.mark.parametrize(
    "failure", ["inside_frame", "missing_support", "outlier", "too_long"]
)
def test_top_boundary_bridge_rejects_unsupported_connections(failure):
    points, frames = boundary_arc(200 if failure == "inside_frame" else 0)
    if failure == "missing_support":
        frames = {t: ds for t, ds in frames.items() if t >= 0.2}
    later = points[9:12]
    if failure == "outlier":
        later = [later[0], ball(1, 900, 100), later[2]]
    if failure == "too_long":
        later = [ball(p.timestamp + 1, *p.center) for p in later]
    assert top_boundary_bridge(points[3], later, frames, (1000, 600)) is None


def archive_payload(video, points, tracks):
    return {
        "schema_version": 1,
        "video_fingerprint": video_fingerprint(video),
        "sample_fps": 10,
        "video_info": asdict(VideoInfo(1000, 1000, 10, 100)),
        "windows": [[0, 5]],
        "frames": [
            {
                "frame_index": i,
                "timestamp": p.timestamp,
                "players": [t.observations[i].to_dict() for t in tracks],
                "balls": [p.to_dict()],
            }
            for i, p in enumerate(points)
        ],
    }


def test_replay_requires_same_video_rate_and_recorded_window(tmp_path):
    video = tmp_path / "fixture.mp4"
    video.write_bytes(b"fixture")
    trajectory, tracks, _ = shot_scene()
    payload = archive_payload(video, trajectory.observations, tracks)
    archive = ObservationArchive(payload, video)
    assert len(archive.window(0, 2, 10)) == len(trajectory.observations)
    with pytest.raises(ValueError, match="RATE_MISMATCH"):
        archive.window(0, 2, 12)
    with pytest.raises(ValueError, match="WINDOW_NOT_RECORDED"):
        archive.window(0, 6, 10)
    video.write_bytes(b"changed-video")
    with pytest.raises(ValueError, match="SOURCE_MISMATCH"):
        ObservationArchive(payload, video)


def test_replay_pipeline_does_not_decode_or_load_a_detector(tmp_path):
    video = tmp_path / "fixture.mp4"
    video.write_bytes(b"fixture")
    trajectory, tracks, event = shot_scene()
    archive = ObservationArchive(
        archive_payload(video, trajectory.observations, tracks), video
    )

    def forbidden(*args):
        raise AssertionError("Replay must not decode or infer")

    pipeline = ShooterAttributionPipeline(
        None,
        None,
        config=AnalysisConfig(sample_fps=10),
        video_reader=forbidden,
        video_inspector=lambda _: VideoInfo(1000, 1000, 10, 100),
    )
    result = pipeline.analyze(video, [event], observation_archive=archive)
    assert result["results"][0]["status"] == "attributed"
    assert result["performance"]["detector_seconds"] == 0
    assert result["performance"]["replayed_observations"]


def test_joint_search_finds_valid_anchor_in_another_nearby_frame():
    trajectory, tracks, event = shot_scene()
    frames = [(p.timestamp, [p]) for p in trajectory.observations]
    frames[-1] = (frames[-1][0], [ball(1.2, 950, 950)])
    paths = ball_path_hypotheses(frames, event.timestamp, (1000, 1000), rim=event.rim)
    assert paths
    assert all(p.observations[-1].timestamp < 1.2 for p, _ in paths)


def test_joint_uncertainty_before_possession_does_not_veto_supported_release():
    trajectory, tracks, event = shot_scene()
    frames = [(p.timestamp, [p]) for p in trajectory.observations]
    frames[1][1].append(ball(0.1, 180, 215, confidence=0.2))
    result, path = JointShooterAttributor().attribute(
        event, frames, tracks, (1000, 1000), tracking_scope="test", sample_fps=10
    )
    assert result["status"] == "attributed"
    assert result["shooter"]["track_id"] == 1
    assert result["method"] == "joint_release_trajectory_v2"


@pytest.mark.parametrize("contextual", [False, True])
def test_joint_equally_plausible_players_still_return_unknown(contextual):
    trajectory, tracks, event = shot_scene()
    tracks[1].observations = list(tracks[0].observations)
    frames = [(p.timestamp, [p]) for p in trajectory.observations]
    result, _ = JointShooterAttributor(contextual=contextual).attribute(
        event, frames, tracks, (1000, 1000), tracking_scope="test", sample_fps=10
    )
    assert result["status"] == "unknown"
    assert result["reason"] == "multiple_plausible_shooters"


@pytest.mark.parametrize("contextual", [False, True])
def test_joint_cannot_bridge_a_long_missing_ball_interval(contextual):
    trajectory, tracks, event = shot_scene()
    frames = [
        (p.timestamp, [p] if p.timestamp <= 0.4 or p.timestamp >= 1 else [])
        for p in trajectory.observations
    ]
    result, _ = JointShooterAttributor(contextual=contextual).attribute(
        event, frames, tracks, (1000, 1000), tracking_scope="test", sample_fps=10
    )
    assert result["status"] == "unknown"


def reference_fixture():
    trajectory, tracks, _ = shot_scene()
    return {
        "video_fingerprint": {"name": "fixture", "size": 42, "mtime_ns": 1},
        "results": [
            {
                "candidate_id": "a",
                "tracking_scope": "old",
                "event_time_ms": 1200,
                "status": "attributed",
                "shooter": {
                    "track_id": 1,
                    "score": 0.9,
                    "release_interval_ms": [400, 500],
                },
                "rankings": [],
            }
        ],
        "sessions": [
            {"tracking_scope": "old", "tracks": [t.to_dict() for t in tracks]}
        ],
    }


def test_spatial_references_follow_confirmed_boxes_when_ids_change():
    import copy

    old = reference_fixture()
    labels = [
        {
            "candidate_id": "a",
            "tracking_scope": "old",
            "is_scoring": True,
            "shooter_track_id": 1,
        }
    ]
    references = build_spatial_references(old, labels)
    new = copy.deepcopy(old)
    new["results"][0]["tracking_scope"] = "new"
    new["results"][0]["shooter"]["track_id"] = 7
    new["sessions"][0]["tracking_scope"] = "new"
    new["sessions"][0]["tracks"][0]["track_id"] = 7
    new["sessions"][0]["tracks"][1]["track_id"] = 8
    report = evaluate_spatial_references(new, references)
    assert report["correct_predictions"] == 1
    assert report["reference_matches"][0]["expected_track_id"] == 7
    assert report["reference_matches"][0]["reference_anchors"] >= 3


def test_ambiguous_spatial_reference_never_counts_as_correct():
    import copy

    old = reference_fixture()
    labels = [
        {
            "candidate_id": "a",
            "tracking_scope": "old",
            "is_scoring": True,
            "shooter_track_id": 1,
        }
    ]
    references = build_spatial_references(old, labels)
    new = copy.deepcopy(old)
    new["sessions"][0]["tracks"][1]["observations"] = new["sessions"][0]["tracks"][0][
        "observations"
    ]
    report = evaluate_spatial_references(new, references)
    assert report["precision"] is None
    assert report["predictions_without_resolvable_truth"] == 1
    assert report["reference_matches"][0]["expected_track_id"] is None


def test_spatial_reference_rejects_other_video_or_changed_event():
    import copy

    old = reference_fixture()
    labels = [
        {
            "candidate_id": "a",
            "tracking_scope": "old",
            "is_scoring": True,
            "shooter_track_id": 1,
        }
    ]
    references = build_spatial_references(old, labels)
    wrong = copy.deepcopy(old)
    wrong["video_fingerprint"]["size"] = 99
    with pytest.raises(ValueError, match="VIDEO_MISMATCH"):
        evaluate_spatial_references(wrong, references)
    wrong = copy.deepcopy(old)
    wrong["results"][0]["event_time_ms"] += 1
    with pytest.raises(ValueError, match="EVENT_MISMATCH"):
        evaluate_spatial_references(wrong, references)
    with pytest.raises(ValueError, match="STALE_LABEL"):
        build_spatial_references(old, [{**labels[0], "tracking_scope": "other"}])
