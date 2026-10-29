"""Independent shot-attempt, outcome and shooter labels; legacy-safe readers."""

from __future__ import annotations


def normalize_shot_label(label):
    """Read old made-basket labels without turning every negative into a miss.

    Old ``is_scoring=False`` establishes only that a basket was not made. It
    does not distinguish a missed attempt from a dribble or a false candidate.
    Free-text notes are never interpreted automatically here.
    """
    result = dict(label)
    if "is_shot" in label:
        is_shot, outcome = label["is_shot"], label.get("shot_outcome")
        if is_shot is not None and type(is_shot) is not bool:
            raise ValueError("SHOT_LABEL_ATTEMPT_INVALID")
        if is_shot is True and outcome not in ("made", "missed", "unknown"):
            raise ValueError("SHOT_LABEL_OUTCOME_INVALID")
        if is_shot is not True and outcome is not None:
            raise ValueError("SHOT_LABEL_OUTCOME_WITHOUT_ATTEMPT")
        if is_shot is False and label.get("shooter_track_id") is not None:
            raise ValueError("SHOT_LABEL_NON_SHOT_HAS_SHOOTER")
        scoring = True if outcome == "made" else None if outcome == "unknown" else False
        if "is_scoring" in label and (
            type(label["is_scoring"]) is not type(scoring)
            or label["is_scoring"] != scoring
        ):
            raise ValueError("SHOT_LABEL_CONTRADICTORY_OUTCOME")
    else:
        if "shot_outcome" in label:
            raise ValueError("SHOT_LABEL_ATTEMPT_REQUIRED")
        scoring = label.get("is_scoring")
        if type(scoring) is not bool:
            raise ValueError("SHOT_LABEL_LEGACY_OUTCOME_INVALID")
        is_shot, outcome = (True, "made") if scoring else (None, None)
    track_id = label.get("shooter_track_id")
    if track_id is not None and (type(track_id) is not int or track_id < 1):
        raise ValueError("SHOT_LABEL_TRACK_INVALID")
    result.update(
        label_schema_version=2,
        is_shot=is_shot,
        shot_outcome=outcome,
        is_scoring=scoring,
    )
    for name in ("player_id", "attempt_id"):
        value = label.get(name)
        if value is not None and (
            not isinstance(value, str) or not value.strip() or len(value) > 200
        ):
            raise ValueError("SHOT_LABEL_ID_INVALID")
    return result


def summarize_linked_field_goals(labels):
    """Sample FGM/FGA only with explicit player and physical-attempt identities.

    Temporary track IDs are never global player IDs, and candidate IDs are never
    silently treated as physical shot IDs. Conflicting duplicate labels are
    excluded instead of inflating an attempt count.
    """
    groups, missing_identity = {}, 0
    for raw in labels:
        label = normalize_shot_label(raw)
        if label["is_shot"] is not True:
            continue
        if not label.get("player_id") or not label.get("attempt_id"):
            missing_identity += 1
            continue
        groups.setdefault(label["attempt_id"], []).append(label)
    players, conflicts, unknown_outcome = {}, [], 0
    for attempt_id, records in groups.items():
        owners = {r["player_id"] for r in records}
        outcomes = {r["shot_outcome"] for r in records} - {"unknown"}
        if len(owners) != 1 or len(outcomes) > 1:
            conflicts.append(attempt_id)
            continue
        if not outcomes:
            unknown_outcome += 1
            continue
        owner, outcome = next(iter(owners)), next(iter(outcomes))
        counts = players.setdefault(owner, {"player_id": owner, "fgm": 0, "fga": 0})
        counts["fga"] += 1
        counts["fgm"] += outcome == "made"
    return {
        "statistic_scope": "explicitly_linked_reviewed_attempt_sample",
        "players": [
            {**counts, "sample_fg_percent": 100 * counts["fgm"] / counts["fga"]}
            for _, counts in sorted(players.items())
        ],
        "labels_missing_player_or_attempt_identity": missing_identity,
        "attempts_with_unknown_outcome": unknown_outcome,
        "conflicting_attempt_ids": sorted(conflicts),
        "full_game_fg_percent": None,
        "full_game_requires_exhaustive_attempt_detection": True,
    }
