"""Frame-by-frame rim crossing check on a tight crop around the rim.

The detector runs on every source frame around a candidate, on a square crop
of about five rim widths, so the ball stays large and no crossing frame is
skipped. A make must:

1. come down from above the rim opening,
2. cross the rim plane close to the rim center,
3. reach the net bottom close to the rim center and keep falling,
4. not bounce back up near the rim,
5. be hidden or blurred for at least one frame while passing the rim/net.
   A ball that falls in front of the rim stays fully visible.

Coordinates are normalized to the rim: x = (x - center_x) / width and
y = (y - rim_y) / width. Thresholds were measured on reviewed projects with
rims of 47-62 px; smaller rims are skipped and left for manual review.
"""

RIM_CHECK_VERSION = "rim-dense-v1"
AUTO_REVIEW_REASON = "auto_rim_check"
MIN_RIM_WIDTH_PX = 30.0
CROP_RIM_WIDTHS = 5.0
MIN_CROP_SIDE_PX = 96.0
WINDOW_BEFORE_S = 1.0
WINDOW_AFTER_S = 1.0

MIN_BALL_CONF = 0.15
STRONG_BALL_CONF = 0.5
MAX_CROSS_OFFSET = 0.45
MAX_EXIT_OFFSET = 0.7
MIN_HIDDEN_FRAMES = 1

_ZONE_X = 2.5
_ZONE_TOP = -2.5
_ZONE_BOTTOM = 3.0


def tight_crop_box(rim, frame_width, frame_height):
    """Square crop centered just below the rim so approach and net exit fit."""
    side = max(MIN_CROP_SIDE_PX, CROP_RIM_WIDTHS * float(rim["width"]))
    side = min(side, float(frame_width), float(frame_height))
    cx = float(rim["center_x"])
    cy = float(rim["rim_y"]) + 0.75 * float(rim["width"])
    x1 = int(round(min(max(0.0, cx - side / 2), frame_width - side)))
    y1 = int(round(min(max(0.0, cy - side / 2), frame_height - side)))
    return [x1, y1, x1 + int(side), y1 + int(side)]


def _frame_balls(detections, rim):
    width = float(rim["width"])
    balls = []
    for item in detections:
        if item.get("name") != "ball" or float(item.get("confidence", 0.0)) < MIN_BALL_CONF:
            continue
        x1, y1, x2, y2 = item["xyxy"]
        x = ((x1 + x2) / 2 - float(rim["center_x"])) / width
        y = ((y1 + y2) / 2 - float(rim["rim_y"])) / width
        if abs(x) <= _ZONE_X and _ZONE_TOP <= y <= _ZONE_BOTTOM:
            balls.append({"x": x, "y": y, "conf": float(item["confidence"])})
    return balls


def _drop_static(frames_balls, radius=0.12, min_frames=6):
    """Remove detections that sit still for many frames (bolts, logos)."""
    flat = [(index, ball) for index, balls in enumerate(frames_balls) for ball in balls]
    static = set()
    for index, ball in flat:
        frames = {
            other_index for other_index, other in flat
            if abs(other["x"] - ball["x"]) <= radius and abs(other["y"] - ball["y"]) <= radius
        }
        if len(frames) >= min_frames:
            static.add((index, id(ball)))
    return [
        [ball for ball in balls if (index, id(ball)) not in static]
        for index, balls in enumerate(frames_balls)
    ]


def _build_tracks(frames_balls, per_frame=0.7, max_gap=12, max_jump=2.0):
    tracks = []
    for index, balls in enumerate(frames_balls):
        for ball in sorted(balls, key=lambda item: -item["conf"]):
            point = {**ball, "i": index}
            best = None
            for track in tracks:
                last = track[-1]
                gap = index - last["i"]
                if gap <= 0 or gap > max_gap:
                    continue
                distance = ((point["x"] - last["x"]) ** 2 + (point["y"] - last["y"]) ** 2) ** 0.5
                if distance <= min(per_frame * gap, max_jump) and (best is None or distance < best[0]):
                    best = (distance, track)
            if best:
                best[1].append(point)
            else:
                tracks.append([point])
    return [track for track in tracks if len(track) >= 3]


def _continuation(after, below, tracks):
    """Append a fragment that starts right after the crossing.

    The net often yields a second box in the same frame, which splits one
    physical fall into two tracks.
    """
    tail = after[-1] if after else below
    for other in tracks:
        first = other[0]
        if (
            below["i"] - 3 <= first["i"] <= tail["i"] + 12
            and -0.1 <= first["y"] <= 1.0
            and abs(first["x"] - tail["x"]) <= 0.8
            and other[-1]["i"] > tail["i"]
        ):
            return after + [point for point in other if point["i"] > tail["i"]]
    return after


def _track_crossings(track, tracks):
    others = [other for other in tracks if other is not track]
    for k in range(len(track) - 1):
        above, below = track[k], track[k + 1]
        if not (above["y"] < 0 <= below["y"]):
            continue
        ratio = -above["y"] / (below["y"] - above["y"])
        x_cross = above["x"] + ratio * (below["x"] - above["x"])
        entry = any(
            -1.2 <= point["y"] <= -0.1 and point["i"] >= above["i"] - 15
            for point in track[:k + 1]
        )
        after = _continuation(track[k + 1:], below, others)
        exits = [point for point in after if point["y"] >= 0.4 and point["i"] - below["i"] <= 20]
        deep = [point for point in after if point["y"] >= 1.0 and point["i"] - below["i"] <= 30]
        rebound = False
        lowest = below["y"]
        for point in after:
            if point["y"] > 1.2:
                break
            if point["y"] < lowest - 0.3:
                rebound = True
                break
            lowest = max(lowest, point["y"])
        last_above = max(
            (point["i"] for point in track[:k + 1] if point["y"] < -0.1),
            default=above["i"],
        )
        first_below = min(
            (point["i"] for point in after if point["y"] >= 0.6),
            default=below["i"],
        )
        seen = {point["i"]: point["conf"] for point in track[:k + 1] + after}
        hidden = sum(
            1 for index in range(last_above + 1, first_below)
            if seen.get(index, 0.0) < STRONG_BALL_CONF
        )
        yield {
            "x_cross": round(x_cross, 3),
            "entry": entry,
            "x_exit": round(exits[0]["x"], 3) if exits else None,
            "reached_net_bottom": bool(deep),
            "rebound": rebound,
            "hidden_frames": hidden,
            "track_points": k + 1 + len(after),
        }


def rejection_reason(crossing):
    """Return why a crossing is not a make, or ``None`` for a make."""
    if crossing is None:
        return "no_crossing"
    if not crossing["entry"]:
        return "no_entry"
    if abs(crossing["x_cross"]) > MAX_CROSS_OFFSET:
        return "off_center"
    if crossing["x_exit"] is None or not crossing["reached_net_bottom"]:
        return "no_exit"
    if abs(crossing["x_exit"]) > MAX_EXIT_OFFSET:
        return "exit_off_center"
    if crossing["rebound"]:
        return "rebound"
    if crossing["hidden_frames"] < MIN_HIDDEN_FRAMES:
        return "not_occluded"
    return None


def _rank(crossing):
    # Rejection reasons are ordered by how far the evidence got; any fragment
    # that proves a make wins over a closer-to-center fragment that lost the
    # ball (rim rollers often split into several fragments).
    order = ["no_entry", "off_center", "no_exit", "exit_off_center", "rebound", "not_occluded", None]
    return (-order.index(rejection_reason(crossing)), abs(crossing["x_cross"]))


def skipped_result(reason, rim_width=None):
    return {
        "version": RIM_CHECK_VERSION,
        "status": "skipped",
        "reason": reason,
        "rim_width_px": round(float(rim_width), 2) if rim_width is not None else None,
    }


def assess_rim_crossing(frames, rim):
    """Judge one candidate from per-frame detections in source coordinates.

    ``frames`` is the ordered list of consecutive source frames; each item is
    a list of detections ``{"name", "confidence", "xyxy"}``.
    """
    rim_width = float(rim["width"])
    if rim_width < MIN_RIM_WIDTH_PX:
        return skipped_result("small_rim", rim_width)
    if not frames:
        return skipped_result("no_frames", rim_width)
    frames_balls = _drop_static([_frame_balls(detections, rim) for detections in frames])
    tracks = _build_tracks(frames_balls)
    crossings = [crossing for track in tracks for crossing in _track_crossings(track, tracks)]
    best = min(crossings, key=_rank) if crossings else None
    reason = rejection_reason(best)
    return {
        "version": RIM_CHECK_VERSION,
        "status": "made" if reason is None else "rejected",
        "reason": reason,
        "rim_width_px": round(rim_width, 2),
        "frames": len(frames),
        **(best or {}),
    }
