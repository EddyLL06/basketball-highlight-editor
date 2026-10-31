"""Shot-local appearance matching against explicitly confirmed reference crops.

Independent of release detection and outcome labels. Scores are similarities,
not probabilities. No predicted identity is ever promoted into the gallery.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path

import numpy as np

PREPROCESS_VERSION = "rgb_imagenet_resize_256x128_v1"


def unit_vector(value):
    vector = np.asarray(value, dtype=np.float32)
    if vector.ndim != 1 or not vector.size or not np.isfinite(vector).all():
        raise ValueError("Invalid appearance feature")
    length = float(np.linalg.norm(vector))
    if length <= 1e-8:
        raise ValueError("Empty appearance feature")
    return vector / length


def feature_key(crop_bytes, model_sha256):
    return hashlib.sha256(
        PREPROCESS_VERSION.encode() + model_sha256.encode() + crop_bytes
    ).hexdigest()


class TorchScriptAppearance:
    """Load a locally prepared, hash-pinned model; never download at runtime."""

    def __init__(self, model_path, sha256):
        path = Path(model_path)
        if len(sha256) != 64 or hashlib.sha256(path.read_bytes()).hexdigest() != sha256:
            raise ValueError("Appearance model hash mismatch")
        import torch

        self.torch = torch
        torch.set_num_threads(min(4, torch.get_num_threads()))
        self.model = torch.jit.load(str(path), map_location="cpu").eval()
        self.sha256 = sha256

    def encode(self, crops):
        import cv2

        if not crops:
            return []
        images = []
        for crop in crops:
            if crop is None or crop.ndim != 3 or crop.shape[2] != 3 or min(crop.shape[:2]) < 4:
                raise ValueError("Invalid person crop")
            image = cv2.resize(crop, (128, 256))[:, :, ::-1].astype(np.float32) / 255
            image = (image - [0.485, 0.456, 0.406]) / [0.229, 0.224, 0.225]
            images.append(image.transpose(2, 0, 1))
        with self.torch.inference_mode():
            tensor = self.torch.from_numpy(np.stack(images).astype(np.float32))
            output = self.model(tensor).cpu().numpy()
        if output.ndim != 2 or len(output) != len(crops):
            raise ValueError("Unexpected appearance model output")
        return [unit_vector(row).tolist() for row in output]


@dataclass(frozen=True)
class IdentityPolicy:
    min_similarity: float = 0.72
    min_margin: float = 0.08
    min_reference_shots: int = 2
    reference_guard_ms: int = 3000

    def __post_init__(self):
        if not (0 <= self.min_similarity <= 1 and 0 < self.min_margin <= 1
                and type(self.min_reference_shots) is int and self.min_reference_shots >= 1
                and type(self.reference_guard_ms) is int and self.reference_guard_ms >= 0):
            raise ValueError("Invalid identity policy")


def reference_related(shot, reference_shot, policy):
    return shot["id"] == reference_shot["id"] or (
        shot.get("group_id") is not None
        and shot["group_id"] == reference_shot.get("group_id")
    ) or (shot["video_id"] == reference_shot["video_id"]
          and abs(shot["event_time_ms"] - reference_shot["event_time_ms"])
          <= policy.reference_guard_ms)


def reference_groups(references, samples, shots, policy=None):
    """Adjacent/duplicate candidates provide one independent reference event."""
    policy = policy or IdentityPolicy()
    players = {}
    for ref in references:
        if ref.get("human_confirmed") is not True:
            continue
        shot = shots[samples[ref["sample_id"]]["shot_id"]]
        groups = players.setdefault(ref["player_id"], {})
        related = [key for key, group in groups.items() if any(
            reference_related(shot, shots[samples[old["sample_id"]]["shot_id"]], policy)
            for old in group)]
        key = min(related) if related else shot["id"]
        combined = [old for old_key in related for old in groups.pop(old_key)]
        groups[key] = combined + [ref]
    return players


def associate_shot(shot, query_samples, references, samples, shots, features, policy=None):
    policy = policy or IdentityPolicy()
    result = {"status": "unknown", "player_id": None, "reason": "gallery_incomplete",
              "score_kind": "cosine_similarity_not_probability", "rankings": []}
    confirmed = [r for r in references if r.get("human_confirmed") is True]
    if any(reference_related(shot, shots[samples[r["sample_id"]]["shot_id"]], policy)
           for r in confirmed):
        return {**result, "status": "reference", "reason": "reference_shot_or_nearby_window"}
    gallery = {}
    for player_id, groups in reference_groups(confirmed, samples, shots, policy).items():
        for group_id, refs in groups.items():
            vectors = [unit_vector(features[samples[ref["sample_id"]]["feature_key"]])
                       for ref in refs if samples[ref["sample_id"]]["feature_key"] in features]
            if vectors:
                gallery.setdefault(player_id, {})[group_id] = vectors
    if len(gallery) < 2 or any(len(group) < policy.min_reference_shots for group in gallery.values()):
        return result
    if shot.get("selected_track_id") is None:
        return {**result, "reason": "shooter_unresolved"}
    query = [unit_vector(features[samples[s]["feature_key"]]) for s in query_samples
             if samples[s]["feature_key"] in features]
    if not query:
        return {**result, "reason": "person_crop_unavailable"}
    if any(v.shape != query[0].shape for v in query):
        raise ValueError("Feature dimensions differ")
    per_frame = []
    for vector in query:
        scores = {}
        for player_id, groups in gallery.items():
            # A reference shot gets one vote even when it has adjacent crops.
            distances = [max(float(vector @ ref) for ref in group) for group in groups.values()]
            scores[player_id] = float(np.mean(sorted(distances, reverse=True)[:2]))
        per_frame.append(scores)
    ranking = sorted(
        ({"player_id": player, "similarity": round(float(np.median([s[player] for s in per_frame])), 5)}
         for player in gallery), key=lambda r: (-r["similarity"], r["player_id"]))
    best, second = ranking[:2]
    margin = best["similarity"] - second["similarity"]
    votes = sum(max(s, key=s.get) == best["player_id"] for s in per_frame)
    result.update(rankings=ranking, margin=round(margin, 5), frames=len(query), agreement=votes)
    reason = "below_similarity_threshold" if best["similarity"] < policy.min_similarity else (
        "similar_players" if margin < policy.min_margin else (
            "frames_disagree" if votes / len(query) < 2 / 3 else "matched_confirmed_references"))
    result["reason"] = reason
    if reason == "matched_confirmed_references":
        result.update(status="suggested", player_id=best["player_id"])
    return result
