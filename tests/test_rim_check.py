from basketball_highlight.rim_check import assess_rim_crossing, tight_crop_box

RIM = {"center_x": 500.0, "rim_y": 300.0, "width": 50.0, "height": 20.0}


def ball(x, y, conf=0.85, rim=RIM):
    """Detection at rim-normalized position (x, y)."""
    cx = rim["center_x"] + x * rim["width"]
    cy = rim["rim_y"] + y * rim["width"]
    half = rim["width"] * 0.25
    return {"name": "ball", "confidence": conf, "xyxy": [cx - half, cy - half, cx + half, cy + half]}


def fall(x_start=0.3, x_end=-0.2, hidden=(), steps=16, extra=None):
    """Ball falling from above the rim to below the net, one frame per step."""
    frames = []
    for step in range(steps):
        y = -1.5 + step * 0.25
        x = x_start + (x_end - x_start) * step / (steps - 1)
        detections = [] if step in hidden else [ball(x, y)]
        if extra:
            detections.append(extra)
        frames.append(detections)
    return frames


def test_ball_hidden_by_net_while_passing_the_rim_is_a_make():
    # Steps 6-7 sit at y=0.0/0.25: the ball is inside the rim and net.
    result = assess_rim_crossing(fall(hidden={6, 7}), RIM)
    assert result["status"] == "made"
    assert result["reason"] is None
    assert result["hidden_frames"] == 2


def test_ball_that_stays_fully_visible_fell_in_front_of_the_rim():
    result = assess_rim_crossing(fall(), RIM)
    assert result["status"] == "rejected"
    assert result["reason"] == "not_occluded"


def test_low_confidence_frames_count_as_occlusion():
    frames = fall()
    frames[6] = [ball(0.07, 0.0, conf=0.3)]
    result = assess_rim_crossing(frames, RIM)
    assert result["status"] == "made"


def test_crossing_outside_the_rim_opening_is_rejected():
    result = assess_rim_crossing(fall(x_start=0.9, x_end=0.6, hidden={6, 7}), RIM)
    assert result["status"] == "rejected"
    assert result["reason"] == "off_center"


def test_ball_bouncing_back_up_near_the_rim_is_rejected():
    frames = fall(hidden={6})
    # Back up from y=0.75 to y=0.25, then falls away.
    frames = frames[:10] + [[ball(0.0, 0.25)], [ball(0.0, 0.3)]] + frames[10:]
    result = assess_rim_crossing(frames, RIM)
    assert result["status"] == "rejected"
    assert result["reason"] == "rebound"


def test_ball_lost_before_leaving_the_net_is_rejected():
    frames = fall(hidden={6, 7})[:9]
    result = assess_rim_crossing(frames, RIM)
    assert result["status"] == "rejected"
    assert result["reason"] == "no_exit"


def test_static_false_detection_does_not_create_a_crossing():
    still = ball(0.1, -0.4, conf=0.6)
    frames = [[still] for _ in range(20)]
    result = assess_rim_crossing(frames, RIM)
    assert result["status"] == "rejected"
    assert result["reason"] == "no_crossing"


def test_static_false_detection_does_not_hide_a_real_make():
    result = assess_rim_crossing(fall(hidden={6, 7}, extra=ball(1.5, -1.0, conf=0.6)), RIM)
    assert result["status"] == "made"


def test_small_rims_are_left_for_manual_review():
    rim = {**RIM, "width": 17.0}
    result = assess_rim_crossing(fall(hidden={6, 7}), rim)
    assert result["status"] == "skipped"
    assert result["reason"] == "small_rim"


def test_tight_crop_stays_inside_the_frame():
    assert tight_crop_box(RIM, 1920, 1080) == [375, 212, 625, 462]
    edge = {**RIM, "center_x": 10.0, "rim_y": 10.0}
    x1, y1, x2, y2 = tight_crop_box(edge, 1920, 1080)
    assert (x1, y1) == (0, 0)
    assert x2 - x1 == y2 - y1 == 250
