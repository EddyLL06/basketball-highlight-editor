"""Prototype rim-crossing verdicts on dense rim-crop detections.

Coordinates are normalized to the rim: x = (x - center_x) / rim_width,
y = (y - rim_y) / rim_width. A make has to enter the rim opening from above,
leave through the net bottom near the rim center, and (for the occlusion rule)
be hidden or blurred by the rim/net for at least one frame while passing it.
"""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from eval_review_labels import report  # noqa: E402

ZONE_X = 2.5
ZONE_TOP = -2.5
ZONE_BOTTOM = 3.0


def frame_balls(frame, rim, sources, min_conf):
    width = float(rim["width"])
    balls = []
    for source in sources:
        for item in frame.get(source, []):
            if item["name"] != "ball" or item["conf"] < min_conf:
                continue
            x1, y1, x2, y2 = item["xyxy"]
            x = ((x1 + x2) / 2 - float(rim["center_x"])) / width
            y = ((y1 + y2) / 2 - float(rim["rim_y"])) / width
            if abs(x) <= ZONE_X and ZONE_TOP <= y <= ZONE_BOTTOM:
                balls.append({"x": x, "y": y, "conf": item["conf"]})
    return balls


def drop_static(frames_balls, radius=0.12, min_frames=6):
    """Remove detections that sit still for many frames (logos, bolts, held balls)."""
    flat = [(index, ball) for index, balls in enumerate(frames_balls) for ball in balls]
    static = set()
    for index, ball in flat:
        neighbours = {
            other_index for other_index, other in flat
            if abs(other["x"] - ball["x"]) <= radius and abs(other["y"] - ball["y"]) <= radius
        }
        if len(neighbours) >= min_frames:
            static.add((index, id(ball)))
    return [
        [ball for ball in balls if (index, id(ball)) not in static]
        for index, balls in enumerate(frames_balls)
    ]


def build_tracks(frames_balls, per_frame=0.7, max_gap=12, max_jump=2.0):
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


def continuation(track_after, b, tracks):
    """Append a fragment that starts right after the crossing.

    The net often yields a second box in the same frame (ball plus its shadow
    behind the mesh), which splits one physical fall into two tracks.
    """
    tail = track_after[-1] if track_after else b
    for other in tracks:
        first = other[0]
        if (
            b["i"] - 3 <= first["i"] <= tail["i"] + 12
            and -0.1 <= first["y"] <= 1.0
            and abs(first["x"] - tail["x"]) <= 0.8
            and other[-1]["i"] > tail["i"]
        ):
            return track_after + [p for p in other if p["i"] > tail["i"]]
    return track_after


def crossing_features(track, tracks, strong_conf=0.5):
    others = [other for other in tracks if other is not track]
    best = None
    for k in range(len(track) - 1):
        a, b = track[k], track[k + 1]
        if not (a["y"] < 0 <= b["y"]):
            continue
        ratio = (0 - a["y"]) / (b["y"] - a["y"])
        x_cross = a["x"] + ratio * (b["x"] - a["x"])
        entry = [p for p in track[:k + 1] if -1.2 <= p["y"] <= -0.1 and p["i"] >= a["i"] - 15]
        after = continuation(track[k + 1:], b, others)
        exit_points = [p for p in after if p["y"] >= 0.4 and p["i"] - b["i"] <= 20]
        deep = [p for p in after if p["y"] >= 1.0 and p["i"] - b["i"] <= 30]
        rebound = False
        lowest = b["y"]
        for p in after:
            if p["y"] > 1.2:
                break
            if p["y"] < lowest - 0.3:
                rebound = True
                break
            lowest = max(lowest, p["y"])
        last_above = max((p["i"] for p in track[:k + 1] if p["y"] < -0.1), default=a["i"])
        first_below = min((p["i"] for p in after if p["y"] >= 0.6), default=b["i"])
        seen = {p["i"]: p["conf"] for p in track[:k + 1] + after}
        hidden = sum(
            1 for i in range(last_above + 1, first_below)
            if seen.get(i, 0.0) < strong_conf
        )
        features = {
            "x_cross": round(x_cross, 2),
            "entry": bool(entry),
            "x_exit": round(exit_points[0]["x"], 2) if exit_points else None,
            "deep_x": round(deep[0]["x"], 2) if deep else None,
            "rebound": rebound,
            "hidden_frames": hidden,
            "points": k + 1 + len(after),
        }
        if best is None or abs(features["x_cross"]) < abs(best["x_cross"]):
            best = features
    return best


def case_features(case, sources, min_conf):
    rim = case["rim"]
    frames_balls = [frame_balls(frame, rim, sources, min_conf) for frame in case["frames"]]
    frames_balls = drop_static(frames_balls)
    tracks = build_tracks(frames_balls)
    candidates = [
        features for track in tracks
        if (features := crossing_features(track, tracks))
    ]
    if not candidates:
        return None
    # Any fragment that proves a make wins over a closer-to-center fragment
    # that lost the ball (rim rollers split into several fragments).
    return min(candidates, key=lambda f: (
        not (geometry_ok(f) and f["hidden_frames"] >= 1),
        not geometry_ok(f),
        abs(f["x_cross"]),
    ))


def geometry_ok(f, cross=0.45, exit_=0.7):
    return bool(
        f and f["entry"] and abs(f["x_cross"]) <= cross
        and f["x_exit"] is not None and abs(f["x_exit"]) <= exit_
        and f["deep_x"] is not None and not f["rebound"]
    )


RULES = {
    "dense_any_crossing": lambda c: c["dense"] is not None,
    "dense_geometry": lambda c: geometry_ok(c["dense"]),
    "dense_geometry+hidden": lambda c: geometry_ok(c["dense"]) and c["dense"]["hidden_frames"] >= 1,
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dense", required=True)
    parser.add_argument("--sources", nargs="+", default=["tight"])
    parser.add_argument("--min-conf", type=float, default=0.15)
    parser.add_argument("--details", action="store_true")
    args = parser.parse_args()
    cases = json.loads(Path(args.dense).read_text(encoding="utf-8"))
    for case in cases:
        case["dense"] = case_features(case, args.sources, args.min_conf)
        case.pop("frames")
        if args.details:
            print(f"{'GOAL' if case['goal'] else 'miss'} {case['project'][:2]} "
                  f"{case['event_ms'] / 1000:6.1f} {case['verdict'][:5]:5s} {case['dense']}")
    print(json.dumps(report(cases, RULES), ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
