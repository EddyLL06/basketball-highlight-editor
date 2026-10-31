import pytest

from engine.python.basketball_engine.release_shooter import (
    expanded_ball_regions,
    flight_position,
    fit_ball_flight,
    select_release_shooter,
    with_release_contacts,
)


def test_expanded_ball_tiles_cover_proxy_with_overlap_and_reject_bad_sizes():
    left, right = expanded_ball_regions(960, 540)
    assert left == (0, 0, 672, 540) and right == (288, 0, 960, 540)
    assert left[2] > right[0]
    for width, height in [(0, 540), (960, 2), (960.5, 540), (True, 540)]:
        with pytest.raises(ValueError):
            expanded_ball_regions(width, height)


def test_proxy_ball_flight_rejects_stationary_distractors_and_is_repeatable():
    records = []
    for i in range(9):
        t = -0.8 + i * 0.1
        records.append(
            {
                "time": 10 + t,
                "balls": [
                    {
                        "x": 250 + 150 * t,
                        "y": 150 + 260 * t + 250 * t * t,
                        "confidence": 0.8,
                    },
                    {"x": 150, "y": 220, "confidence": 0.9},
                ],
            }
        )
    kwargs = {
        "event_time": 10,
        "rim": {"center_x": 250, "rim_y": 150, "width": 20},
        "frame_size": (400, 300),
    }
    result = fit_ball_flight(records, **kwargs)
    assert result is not None and result["support"] == 9
    assert result["x_coefficients"] == pytest.approx([150, 250])
    assert result["y_coefficients"] == pytest.approx([250, 260, 150])
    assert fit_ball_flight(records, **kwargs) == result
    assert fit_ball_flight(records[:3], **kwargs) is None
    still = [{"time": r["time"], "balls": [r["balls"][1]]} for r in records]
    assert fit_ball_flight(still, **kwargs) is None
    assert fit_ball_flight(still, **kwargs, expanded=True) is None


def test_expanded_fallback_can_find_flight_before_a_late_rim_event():
    records = []
    for i in range(9):
        t = -0.8 + i * 0.1
        records.append(
            {
                "time": 10 + t,
                "balls": [
                    {
                        "x": 250 + 150 * t + 60 * t * t,
                        "y": 150 + 260 * t + 250 * t * t,
                        "confidence": 0.8,
                    }
                ],
            }
        )
    kwargs = {
        "event_time": 11,
        "rim": {"center_x": 250, "rim_y": 150, "width": 20},
        "frame_size": (600, 300),
    }
    assert fit_ball_flight(records, **kwargs) is None
    result = fit_ball_flight(records, **kwargs, expanded=True)
    assert result is not None and result["support"] == 9
    assert len(result["x_coefficients"]) == 3
    assert flight_position(result, 10) == pytest.approx((250, 150))
    # A late candidate after a rim bounce can still refer to the initial flight.
    kwargs["event_time"] = 11.6
    assert fit_ball_flight(records, **kwargs, expanded=True) is None
    earlier = fit_ball_flight(records, **kwargs, expanded=True, earlier_rim_seconds=2.6)
    assert earlier is not None and flight_position(earlier, 10) == pytest.approx((250, 150))
    for bad in (True, -1, 2.7, float("nan"), "2"):
        with pytest.raises(ValueError, match="BALL_SEARCH_TIME_INVALID"):
            fit_ball_flight(records, **kwargs, expanded=True, earlier_rim_seconds=bad)


def person(identifier, box):
    return {"id": identifier, "bbox": box, "confidence": 0.9}


def flight():
    return {
        "launch": {"time": 1.0, "observed": True},
        "observations": [
            {"time": 1.0, "x": 100, "y": 100, "confidence": 0.8},
            {"time": 1.2, "x": 102, "y": 80, "confidence": 0.8},
            {"time": 1.4, "x": 110, "y": 40, "confidence": 0.8},
        ],
    }


def test_upper_body_contact_beats_nearby_persons_feet():
    frames = [
        {
            "time": t,
            "people": [
                person("shooter", [80, 100, 120, 220]),
                person("bystander", [90, 0, 130, 100]),
            ],
        }
        for t in (1.0, 1.2)
    ]
    result = select_release_shooter(frames, flight())
    assert result["status"] == "predicted" and result["selected_track_id"] == 1
    assert result["rankings"][0]["evidence_frame"]["person_id"] == "shooter"
    assert result["score_kind"] == "heuristic_not_probability"


def test_overlapping_people_remain_ambiguous_and_no_flight_cannot_assign():
    frames = [
        {
            "time": 1.0,
            "people": [
                person("a", [80, 100, 120, 220]),
                person("b", [80, 100, 120, 220]),
            ],
        }
    ]
    result = select_release_shooter(frames, flight())
    assert (
        result["status"] == "unknown" and result["reason"] == "nearby_people_ambiguous"
    )
    assert select_release_shooter(frames, None)["selected_track_id"] is None


def test_sparse_departure_is_tentative_and_extrapolation_is_not_contact():
    observed = flight()
    observed["observations"] = [
        observed["observations"][0],
        {"time": 2.0, "x": 200, "y": 30, "confidence": 0.8},
    ]
    frames = [{"time": 1.0, "people": [person("a", [80, 100, 120, 220])]}]
    result = select_release_shooter(frames, observed)
    assert result["status"] == "predicted" and result["confidence_band"] == "tentative"
    frames[0]["time"] = 0.6
    assert select_release_shooter(frames, observed)["status"] == "unknown"


def test_actual_held_ball_can_disambiguate_shooter_from_airborne_defender():
    arc = {
        "event_time": 2.0, "launch": {"time": 1.0, "observed": True},
        "x_coefficients": [100, 200], "y_coefficients": [300, 300, 100],
        "residual_threshold_px": 8,
        "observations": [
            {"time": 1.0, "x": 100, "y": 100, "confidence": .8},
            {"time": 1.2, "x": 120, "y": 52, "confidence": .8},
            {"time": 1.4, "x": 140, "y": 28, "confidence": .8},
        ],
    }
    frames = [
        {"time": .8, "people": [person("defender", [100, 100, 160, 260]), person("shooter", [50, 160, 100, 280])]},
        {"time": 1.0, "people": [person("defender2", [90, 90, 150, 250]), person("shooter2", [40, 150, 90, 270])]},
    ]
    assert select_release_shooter(frames, arc)["selected_track_id"] == 1
    raw = [{"time": .8, "balls": [{"x": 75, "y": 160, "confidence": .8}]}]
    extended = with_release_contacts(arc, raw, frame_size=(400, 300))
    assert len(arc["observations"]) == 3 and "contact_observations" not in arc
    decision = select_release_shooter(frames, extended)
    assert decision["selected_track_id"] == 2
    assert decision["rankings"][0]["evidence_frame"]["ball"]["source"] == "observed_release_neighbour"


def test_release_contact_gate_does_not_invent_or_accept_unrelated_balls():
    arc = {**flight(), "event_time": 2.0, "x_coefficients": [100, 200],
           "y_coefficients": [300, 300, 100], "residual_threshold_px": 8}
    bad = [{"time": .8, "balls": [
        {"x": 75, "y": 170, "confidence": .2},
        {"x": 350, "y": 170, "confidence": .99},
        {"x": float("nan"), "y": 170, "confidence": .9},
    ]}, {"time": .2, "balls": [{"x": 75, "y": 170, "confidence": .9}]}]
    extended = with_release_contacts(arc, bad, frame_size=(400, 300))
    assert extended["contact_observations"] == arc["observations"]
    assert with_release_contacts(None, bad, frame_size=(400, 300)) is None
    frames = [{"time": .8, "people": [person("a", [50, 160, 100, 280])]}]
    assert select_release_shooter(frames, extended)["status"] == "unknown"
