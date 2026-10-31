import pytest

from engine.python.basketball_engine.release_shooter import (
    fit_ball_flight,
    select_release_shooter,
)


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
