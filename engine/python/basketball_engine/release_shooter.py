"""Shot-local shooter hypotheses from proxy ball flight and person boxes.

No player names, reference portraits or cross-shot identities are consumed.
All coordinates and timestamps supplied together must share one proxy timeline.
Scores are heuristic evidence strengths, never calibrated probabilities.
"""

from __future__ import annotations

import itertools
import math

import numpy as np

METHOD = "proxy_ball_release_shooter_v1"


def expanded_ball_regions(width, height):
    """Two overlapping proxy tiles for a failed first-pass ball search only.

    Ball inference may cover the court; this is never a person-search fallback.
    Each tile preserves more ball pixels at the existing 640 model input size.
    """
    if type(width) is not int or type(height) is not int or min(width, height) < 32:
        raise ValueError("BALL_PROXY_SIZE_INVALID")
    span = math.ceil(width * 0.7)
    return [(0, 0, span, height), (width - span, 0, width, height)]


def flight_position(flight, time):
    t = time - flight["event_time"]
    a, b, c = flight["y_coefficients"]
    return float(np.polyval(flight["x_coefficients"], t)), a * t * t + b * t + c


def fit_ball_flight(
    records, *, event_time, rim, frame_size, expanded=False, earlier_rim_seconds=1.4
):
    """Robustly fit one descending-at-rim flight, ignoring stationary false balls."""
    width, height = frame_size
    if type(expanded) is not bool:
        raise ValueError("BALL_SEARCH_MODE_INVALID")
    if (
        isinstance(earlier_rim_seconds, bool)
        or not isinstance(earlier_rim_seconds, (int, float))
        or not math.isfinite(earlier_rim_seconds)
        or not 0 <= earlier_rim_seconds <= 2.6
    ):
        raise ValueError("BALL_SEARCH_TIME_INVALID")
    earlier_rim_seconds = earlier_rim_seconds if expanded else 0
    max_trials = 4000 if expanded else 1200
    points = []
    for record in records:
        for ball in record.get("balls", []):
            try:
                p = [
                    float(record["time"]) - event_time,
                    float(ball["x"]),
                    float(ball["y"]),
                    float(ball["confidence"]),
                ]
                if (
                    all(math.isfinite(v) for v in p)
                    and -3.6 <= p[0] <= 0.3
                    and 0.1 <= p[3] <= 1
                ):
                    points.append(p)
            except (KeyError, ValueError, TypeError):
                continue
    if len(points) < 4:
        return None
    data = np.array(points)
    times, xs, ys, confidence = data.T
    threshold = max(8.0, width * 0.014)
    rim_x, rim_y = rim["center_x"], rim["rim_y"]

    def valid(xc, yc):
        if expanded:
            discriminant = yc[1] ** 2 - 4 * yc[0] * (yc[2] - rim_y)
            if not height * 0.025 < yc[0] < height * 5 or discriminant <= 0:
                return False
            crossing = (-yc[1] + math.sqrt(discriminant)) / (2 * yc[0])
            return (
                -earlier_rim_seconds <= crossing <= 0.3
                and abs(np.polyval(xc, crossing) - rim_x)
                <= max(rim["width"] * 3, width * 0.22)
                and abs(xc[0]) <= width * 1.5
                and abs(2 * xc[0] * crossing + xc[1]) <= width * 2
            )
        return (
            height * 0.025 < yc[0] < height * 5
            and yc[1] > height * 0.02
            and abs(xc[0]) <= width * 2
            and abs(xc[1] - rim_x) <= max(rim["width"] * 3, width * 0.22)
            and abs(yc[2] - rim_y) <= max(rim["width"] * 2.5, height * 0.22)
        )

    def inliers(xc, yc):
        distance = np.hypot(xs - np.polyval(xc, times), ys - np.polyval(yc, times))
        indices = []
        for time in sorted(set(times)):
            group = np.flatnonzero(times == time)
            nearest = min(group, key=lambda i: (distance[i], -confidence[i]))
            if distance[nearest] <= threshold:
                indices.append(nearest)
        return np.array(indices, dtype=int), distance

    n = len(points)
    if math.comb(n, 3) <= max_trials:
        triples = itertools.combinations(range(n), 3)
    else:
        rng = np.random.default_rng(0)
        triples = (sorted(rng.choice(n, 3, replace=False)) for _ in range(max_trials))
    best = None
    for triple in triples:
        selected = list(triple)
        ts = times[selected]
        if len(set(ts)) < 3 or max(ts) - min(ts) < (0.4 - 1e-6 if expanded else 0.4):
            continue
        design = np.column_stack((ts * ts, ts, np.ones(3)))
        try:
            yc = np.linalg.solve(design, ys[selected])
            x_design = design if expanded else np.column_stack((ts, np.ones(3)))
            xc = np.linalg.lstsq(x_design, xs[selected], rcond=None)[0]
        except np.linalg.LinAlgError:
            continue
        if not valid(xc, yc):
            continue
        indices, errors = inliers(xc, yc)
        if (
            len(indices) < 4
            or max(times[indices]) < -earlier_rim_seconds - 0.55
            or np.ptp(times[indices]) < 0.5
        ):
            continue
        score = (
            len(indices)
            + float(confidence[indices].sum()) * 0.15
            - float(errors[indices].mean()) / threshold * 0.35
        )
        if expanded:
            crossing = (
                -yc[1] + math.sqrt(yc[1] ** 2 - 4 * yc[0] * (yc[2] - rim_y))
            ) / (2 * yc[0])
            score += max(0.0, -crossing) * 0.35
        if best is None or score > best[0]:
            best = score, indices, xc, yc
    if best is None:
        return None
    _, indices, xc, yc = best
    ts = times[indices]
    refined_y = np.linalg.lstsq(
        np.column_stack((ts * ts, ts, np.ones(len(ts)))), ys[indices], rcond=None
    )[0]
    x_design = (
        np.column_stack((ts * ts, ts, np.ones(len(ts))))
        if expanded
        else np.column_stack((ts, np.ones(len(ts))))
    )
    refined_x = np.linalg.lstsq(x_design, xs[indices], rcond=None)[0]
    if valid(refined_x, refined_y):
        xc, yc = refined_x, refined_y
        indices, errors = inliers(xc, yc)
    else:
        _, errors = inliers(xc, yc)
    if len(indices) < 4:
        return None
    observed = [
        {
            "time": float(times[i] + event_time),
            "x": float(xs[i]),
            "y": float(ys[i]),
            "confidence": float(confidence[i]),
        }
        for i in indices
    ]
    ascending = [
        p
        for p in observed
        if 2 * yc[0] * (p["time"] - event_time) + yc[1] < -height * 0.08
        and p["time"] <= event_time - 0.25
        and p["y"] >= height * 0.22
    ]
    if ascending:
        launch = {**ascending[0], "observed": True}
    else:
        discriminant = yc[1] ** 2 - 4 * yc[0] * (yc[2] - height * 0.38)
        if discriminant <= 0:
            return None
        t = float((-yc[1] - math.sqrt(discriminant)) / (2 * yc[0]))
        if not -0.25 >= t >= -3.2 or min(times[indices]) - t > 1.2:
            return None
        launch = {
            "time": event_time + t,
            "x": float(np.polyval(xc, t)),
            "y": height * 0.38,
            "observed": False,
        }
    if not 0 <= launch["x"] < width or not 0 <= launch["y"] < height:
        return None
    return {
        "event_time": event_time,
        "x_coefficients": xc.tolist(),
        "y_coefficients": yc.tolist(),
        "observations": observed,
        "launch": launch,
        "support": len(observed),
        "mean_residual_px": float(errors[indices].mean()),
        "residual_threshold_px": threshold,
    }


def _ascending_release_pair(ball, flight):
    """Require two actual rising detections to support a preceding held ball."""
    future = sorted(
        (p for p in flight["observations"]
         if 0.12 <= p["time"] - ball["time"] <= 0.7
         and p["confidence"] >= 0.35),
        key=lambda p: p["time"],
    )
    if len(future) < 2:
        return False
    first, second = future[:2]
    if first["time"] - ball["time"] > 0.25 or second["time"] - first["time"] > 0.45:
        return False
    before = (first["x"] - ball["x"], first["y"] - ball["y"])
    after = (second["x"] - first["x"], second["y"] - first["y"])
    if before[1] > -4 or after[1] > -4:
        return False
    product = math.hypot(*before) * math.hypot(*after)
    return product > 0 and sum(a * b for a, b in zip(before, after)) / product >= 0.7


def refine_release_anchor(flight, records, *, frame_size):
    """Revisit a weak isolated launch hint using an actual later rising ball.

    A lone low-confidence inlier followed by a long gap can be a dribble before
    the shot. Keep the arc intact and move only the regional sampling hint.
    """
    if flight is None:
        return None
    launch = flight["launch"]
    if not launch["observed"] or launch.get("confidence", 1) >= 0.25:
        return flight
    later = [p for p in flight["observations"] if p["time"] > launch["time"] + 0.01]
    if not later or min(p["time"] for p in later) - launch["time"] < 0.6 - 1e-6:
        return flight
    width, height = frame_size
    choices = []
    for record in records:
        try:
            stamp = float(record["time"])
        except (KeyError, TypeError, ValueError):
            continue
        if not launch["time"] + 0.2 - 1e-6 <= stamp <= launch["time"] + 0.8 + 1e-6:
            continue
        expected_x, expected_y = flight_position(flight, stamp)
        for ball in record.get("balls", []):
            try:
                x, y, confidence = (float(ball[k]) for k in ("x", "y", "confidence"))
            except (KeyError, TypeError, ValueError):
                continue
            observed = {"time": stamp, "x": x, "y": y, "confidence": confidence}
            if (
                all(math.isfinite(v) for v in (x, y, confidence))
                and 0 <= x < width and height * 0.22 <= y <= height * 0.75
                and 0.35 <= confidence <= 1
                and math.hypot(x - expected_x, y - expected_y)
                <= max(3 * flight["residual_threshold_px"], height * 0.1)
                and _ascending_release_pair(observed, flight)
            ):
                choices.append(observed)
    if not choices:
        return flight
    chosen = min(choices, key=lambda p: (p["time"], -p["confidence"]))
    return {**flight, "launch": {**chosen, "observed": True},
            "original_launch": dict(launch), "launch_refinement": "observed_rise_after_weak_isolated_hint"}


def with_release_contacts(flight, records, *, frame_size):
    """Attach actual nearby release observations without changing the fitted arc.

    A held ball need not lie exactly on its subsequent free-flight parabola.
    Search only 0.4 seconds either side of the launch hint, with a bounded
    residual and confidence gate. Polynomial positions only gate detections;
    they never become contact evidence themselves.
    A weak preceding detection additionally needs two consistent rising points.
    """
    if flight is None:
        return None
    width, height = frame_size
    launch_time = flight["launch"]["time"]
    gate = max(3 * flight["residual_threshold_px"], height * 0.1)
    contacts = {p["time"]: dict(p) for p in flight["observations"]}
    for record in records:
        try:
            stamp = float(record["time"])
        except (KeyError, TypeError, ValueError):
            continue
        if not math.isfinite(stamp) or not launch_time - 0.4 <= stamp <= launch_time + 0.4:
            continue
        if stamp in contacts:
            continue
        expected_x, expected_y = flight_position(flight, stamp)
        eligible = []
        for ball in record.get("balls", []):
            try:
                x, y, confidence = (float(ball[k]) for k in ("x", "y", "confidence"))
            except (KeyError, TypeError, ValueError):
                continue
            if not (
                all(math.isfinite(v) for v in (x, y, confidence))
                and 0 <= x < width and 0 <= y < height
                and 0.25 <= confidence <= 1
            ):
                continue
            observed = {"time": stamp, "x": x, "y": y, "confidence": confidence}
            if confidence < 0.35 and not (
                0.12 <= launch_time - stamp <= 0.25
                and _ascending_release_pair(observed, flight)
            ):
                continue
            distance = math.hypot(x - expected_x, y - expected_y)
            if distance <= gate:
                eligible.append((distance, -confidence, x, y, confidence))
        if eligible:
            _, _, x, y, confidence = min(eligible)
            contacts[stamp] = {
                "time": stamp, "x": x, "y": y, "confidence": confidence,
                "source": "observed_release_neighbour",
            }
    return {**flight, "contact_observations": [contacts[t] for t in sorted(contacts)]}


def _box_match(a, b):
    aw, ah = a[2] - a[0], a[3] - a[1]
    bw, bh = b[2] - b[0], b[3] - b[1]
    if min(aw, ah, bw, bh) <= 0:
        return math.inf
    delta = math.hypot(
        (a[0] + a[2] - b[0] - b[2]) / 2, (a[1] + a[3] - b[1] - b[3]) / 2
    ) / max(ah, bh)
    return delta + 0.2 * abs(math.log(ah / bh)) + 0.1 * abs(math.log(aw / bw))


def local_person_tracks(frames):
    """Short geometric continuity only; IDs are discarded at each shot boundary."""
    tracks = []
    for frame in sorted(frames, key=lambda f: f["time"]):
        people = frame.get("people", [])
        pairs = []
        for i, track in enumerate(tracks):
            last = track["observations"][-1]
            if 0 < frame["time"] - last["time"] <= 0.41:
                for j, person in enumerate(people):
                    cost = _box_match(last["bbox"], person["bbox"])
                    if cost < 0.65:
                        pairs.append((cost, i, j))
        used_tracks, used_people = set(), set()
        for _, i, j in sorted(pairs):
            if i not in used_tracks and j not in used_people:
                tracks[i]["observations"].append({**people[j], "time": frame["time"]})
                used_tracks.add(i)
                used_people.add(j)
        for j, person in enumerate(people):
            if j not in used_people:
                tracks.append(
                    {
                        "id": len(tracks) + 1,
                        "observations": [{**person, "time": frame["time"]}],
                    }
                )
    return tracks


def _contact(box, ball):
    x1, y1, x2, y2 = box
    h, w = y2 - y1, x2 - x1
    if h <= 0 or w <= 0:
        return 0.0
    dx = max(0.0, abs(ball["x"] - (x1 + x2) / 2) - w * 0.35) / h
    dy = (ball["y"] - y1) / h
    vertical = max(0.0, -0.2 - dy, dy - 0.3)
    if dy > 0.55 or dx > 0.6:
        return 0.0
    return math.exp(-5 * (dx + vertical + abs(dy) * 0.25))


def _stationary_contact_conflict(rankings, tracks):
    """Veto ambiguous airborne proximity; jumping alone never assigns a shooter."""
    if not rankings:
        return False
    best = rankings[0]["evidence_frame"]
    box, ball, stamp = best["bbox"], best["ball"], best["time"]
    if ball["y"] > box[1] - 0.04 * (box[3] - box[1]):
        return False

    def lift(track):
        before = [p for p in track["observations"] if stamp - 0.41 <= p["time"] <= stamp]
        if len(before) < 3:
            return None
        baseline = before[0]["bbox"][3]
        height = max(p["bbox"][3] - p["bbox"][1] for p in before)
        return max(baseline - p["bbox"][3] for p in before) / max(1, height)

    selected = next(t for t in tracks if t["id"] == rankings[0]["track_id"])
    own_lift = lift(selected)
    if own_lift is None or own_lift > 0.04:
        return False
    for track in tracks:
        if track is selected:
            continue
        rival_lift = lift(track)
        person = next((p for p in track["observations"] if abs(p["time"] - stamp) < 0.04), None)
        if rival_lift is not None and rival_lift >= 0.1 and person is not None:
            if _contact(person["bbox"], ball) >= 0.4:
                return True
    return False


def _release_gap_supported(evidence, flight):
    """A weak contact cannot bridge a long unexplained visible-flight gap.

    Gaps at the upper image boundary remain valid: the ball can leave the
    frame near the apex. Polynomial positions only explain missing evidence;
    they never become observed contacts.
    """
    ball = evidence["ball"]
    if ball["confidence"] >= 0.5 or "y_coefficients" not in flight:
        return True
    later = [p for p in flight["observations"] if p["time"] > ball["time"] + 0.04]
    if not later:
        return False
    following = min(later, key=lambda p: p["time"])
    if following["time"] - ball["time"] <= 0.45:
        return True
    start = ball["time"] - flight["event_time"]
    end = following["time"] - flight["event_time"]
    a, b, c = flight["y_coefficients"]
    times = [start, end]
    if a > 0 and start < -b / (2 * a) < end:
        times.append(-b / (2 * a))
    margin = max(8.0, 3 * flight.get("residual_threshold_px", 8.0))
    return min(a * t * t + b * t + c for t in times) <= margin


def select_release_shooter(frames, flight):
    """Choose a shot-local person using observed ball contact and departure."""
    tracks = local_person_tracks(frames)
    result = {
        "method": METHOD,
        "status": "unknown",
        "selected_track_id": None,
        "confidence_band": "insufficient",
        "score_kind": "heuristic_not_probability",
        "reason": "ball_flight_unavailable",
        "rankings": [],
        "tracks": tracks,
    }
    if flight is None:
        return result
    launch = flight["launch"]
    for track in tracks:
        contacts = []
        for person in track["observations"]:
            if not launch["time"] - 0.65 <= person["time"] <= launch["time"] + 0.4:
                continue
            # Contact evidence must be an actual observation, never an extrapolated ball.
            nearby = [
                p
                for p in flight.get("contact_observations", flight["observations"])
                if abs(p["time"] - person["time"]) < 0.04
            ]
            for ball in nearby:
                contact = _contact(person["bbox"], ball)
                contacts.append(
                    {
                        "score": contact,
                        "time": person["time"],
                        "person_id": person["id"],
                        "bbox": person["bbox"],
                        "ball": ball,
                        "person_confidence": person["confidence"],
                    }
                )
        if not contacts:
            continue
        best = max(
            contacts, key=lambda c: (c["score"], -abs(c["time"] - launch["time"]))
        )
        nearby = [c["score"] for c in contacts if abs(c["time"] - best["time"]) <= 0.21]
        future = [
            p for p in flight["observations"] if 0.15 <= p["time"] - best["time"] <= 1.2
        ]
        departure = max(
            (
                1 - _contact(best["bbox"], p)
                for p in future
                if p["y"] < best["ball"]["y"] - 4
            ),
            default=0.0,
        )
        score = (
            0.7 * best["score"] + 0.15 * sum(nearby) / len(nearby) + 0.15 * departure
        )
        reliability = 1.0
        if len(track["observations"]) == 1 and best["person_confidence"] < 0.5:
            reliability = 0.75 + 0.25 * best["person_confidence"] / 0.5
            score *= reliability
        result["rankings"].append(
            {
                "track_id": track["id"],
                "score": round(score, 4),
                "evidence_reliability": round(reliability, 4),
                "contact_score": round(best["score"], 4),
                "departure_score": round(departure, 4),
                "contact_frames": len(contacts),
                "evidence_frame": best,
            }
        )
    result["rankings"].sort(key=lambda r: (-r["score"], r["track_id"]))
    rankings = result["rankings"]
    # Prefer a clearly held ball immediately before free flight over a later
    # airborne ball that merely passes close to a defender's raised hands.
    ownership = []
    for ball in flight.get("contact_observations", []):
        if not (
            0.12 <= launch["time"] - ball["time"] <= 0.25
            and ball["confidence"] >= 0.25
            and _ascending_release_pair(ball, flight)
        ):
            continue
        matching = []
        for track in tracks:
            for person in track["observations"]:
                if abs(person["time"] - ball["time"]) < 0.04:
                    matching.append((
                        _contact(person["bbox"], ball), track["id"], person
                    ))
        matching.sort(key=lambda p: (-p[0], p[1]))
        if not matching or matching[0][0] < 0.75:
            continue
        gap = matching[0][0] - (matching[1][0] if len(matching) > 1 else 0)
        if gap >= 0.25:
            ownership.append((ball["time"], gap, ball, matching))
    if ownership:
        _, gap, ball, matching = max(ownership, key=lambda p: (p[0], p[1]))
        contacts = {track_id: (score, person) for score, track_id, person in matching}
        for rank in rankings:
            score, person = contacts.get(rank["track_id"], (0.0, None))
            if person is not None:
                rank["departure_score"] = round(max(
                    (1 - _contact(person["bbox"], p) for p in flight["observations"]
                     if 0.15 <= p["time"] - ball["time"] <= 1.2
                     and p["y"] < ball["y"] - 4), default=0.0,
                ), 4)
            rank["flight_contact_score"] = rank["contact_score"]
            rank["pre_release_contact_score"] = round(score, 4)
            rank["score"] = round(
                0.65 * score + 0.2 * rank["departure_score"] + 0.15 * rank["score"], 4
            )
            if person is not None:
                rank["contact_score"] = round(score, 4)
                rank["evidence_frame"] = {
                    "score": score, "time": person["time"], "person_id": person["id"],
                    "bbox": person["bbox"], "ball": ball,
                    "person_confidence": person["confidence"],
                }
        rankings.sort(key=lambda r: (-r["score"], r["track_id"]))
        result["pre_release_ownership"] = {"time": ball["time"], "contact_margin": round(gap, 4)}
    if not ownership and _stationary_contact_conflict(rankings, tracks):
        result["reason"] = "airborne_contact_conflicts_with_nearby_release_motion"
        return result
    if rankings and not _release_gap_supported(rankings[0]["evidence_frame"], flight):
        result["reason"] = "weak_release_contact_has_unexplained_flight_gap"
        return result
    if (
        not rankings
        or rankings[0]["contact_score"] < 0.5
        or rankings[0]["departure_score"] < 0.25
    ):
        result["reason"] = "release_contact_or_departure_missing"
        return result
    margin = rankings[0]["score"] - (rankings[1]["score"] if len(rankings) > 1 else 0)
    result["margin"] = round(margin, 4)
    if margin < 0.08:
        result["reason"] = "nearby_people_ambiguous"
        return result
    result.update(
        status="predicted",
        selected_track_id=rankings[0]["track_id"],
        confidence_band="strong"
        if margin >= 0.2
        and rankings[0]["score"] >= 0.8
        and rankings[0]["contact_frames"] >= 2
        and rankings[0]["evidence_frame"]["ball"]["confidence"] >= 0.35
        and launch["observed"]
        else "tentative",
        reason="observed_pre_release_ownership_then_departure" if ownership
        else "observed_ball_upper_body_contact_then_departure",
    )
    return result
