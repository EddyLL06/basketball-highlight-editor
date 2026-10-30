import hashlib
import threading

import numpy as np
import pytest

from engine.python.basketball_engine.adapters.analysis import PipelineCancelled
from engine.python.basketball_engine.person_candidates import (
    RegionPersonCandidates,
    RegionPolicy,
    YoloPersonCropDetector,
)
from engine.python.basketball_engine.protocol import ProtocolError


class FakeDetector:
    def __init__(self, responses):
        self.responses = iter(responses)
        self.images = []

    def detect(self, image):
        self.images.append(image.copy())
        return next(self.responses)


def test_detector_only_receives_crop_and_boxes_map_back_to_proxy():
    frame = np.arange(200 * 300 * 3, dtype=np.uint8).reshape(200, 300, 3)
    detector = FakeDetector([[{"bbox": [1, 2, 30, 60], "confidence": 0.8}]])
    result = RegionPersonCandidates(detector).infer(
        frame, [40, 20, 120, 100], release_point=(55, 18)
    )
    assert np.array_equal(detector.images[0], frame[20:100, 40:120])
    assert result["people"][0]["bbox"] == [41, 22, 70, 80]
    assert result["attempts"] == 1 and result["status"] == "detected"


@pytest.mark.parametrize("success_on_retry", [False, True])
def test_empty_region_has_only_one_small_retry(success_on_retry):
    second = [{"bbox": [2, 3, 30, 60], "confidence": 0.9}] if success_on_retry else []
    detector = FakeDetector([[], second])
    result = RegionPersonCandidates(detector).infer(
        np.zeros((100, 200, 3), np.uint8), [60, 20, 100, 80]
    )
    assert [image.shape[:2] for image in detector.images] == [(60, 40), (72, 48)]
    assert result["attempts"] == 2
    assert result["status"] == ("detected" if success_on_retry else "no_person")
    assert result["examined_pixels"] == sum(
        image.shape[0] * image.shape[1] for image in detector.images
    )
    assert all(
        image.shape[0] * image.shape[1] <= 100 * 200 * 0.5 for image in detector.images
    )
    if success_on_retry:
        assert result["people"][0]["bbox"] == [58, 17, 86, 74]


@pytest.mark.parametrize(
    "region",
    [
        None,
        [0, 0],
        [0, 0, float("nan"), 40],
        [0, 0, 200, 100],
        [-100, -100, 400, 200],
        [500, 500, 600, 600],
        [1, 1, 2, 2],
    ],
)
def test_missing_invalid_or_oversized_region_never_becomes_full_frame(region):
    detector = FakeDetector([])
    result = RegionPersonCandidates(detector).infer(
        np.zeros((100, 200, 3), np.uint8), region
    )
    assert result["people"] == [] and result["attempts"] == 0
    assert detector.images == []


def test_nearby_people_are_retained_and_invalid_detections_are_ignored():
    detector = FakeDetector(
        [
            [
                {"bbox": [3, 4, 40, 65], "confidence": 0.8},
                {"bbox": [4, 4, 41, 65], "confidence": 0.9},
                {"bbox": [4, 4, 10, 20], "confidence": float("nan")},
                {"bbox": [20, 20, 4, 4], "confidence": 0.9},
            ]
        ]
    )
    result = RegionPersonCandidates(detector).infer(
        np.zeros((200, 300, 3), np.uint8), [50, 30, 130, 110]
    )
    assert len(result["people"]) == 2
    assert len(detector.images) == 1


def test_cancellation_between_attempts_does_not_run_retry():
    cancel = threading.Event()

    class CancellingDetector(FakeDetector):
        def detect(self, image):
            cancel.set()
            return super().detect(image)

    detector = CancellingDetector([[]])
    with pytest.raises(PipelineCancelled):
        RegionPersonCandidates(detector).infer(
            np.zeros((100, 200, 3), np.uint8), [50, 20, 100, 80], cancel=cancel
        )
    assert len(detector.images) == 1


@pytest.mark.parametrize(
    "options",
    [
        {"retry_scale": 2},
        {"max_area_fraction": 1},
        {"max_people": 2.5},
        {"min_side": 2},
        {"min_confidence": float("nan")},
    ],
)
def test_policy_rejects_unbounded_or_invalid_settings(options):
    with pytest.raises(ValueError):
        RegionPolicy(**options)


def test_model_must_be_local_and_verified_before_loading(tmp_path):
    with pytest.raises(ProtocolError, match="未安装"):
        YoloPersonCropDetector(tmp_path / "missing.pt")
    weights = tmp_path / "wrong.pt"
    weights.write_bytes(b"not the supported person model")
    with pytest.raises(ProtocolError, match="校验"):
        YoloPersonCropDetector(weights)


def test_crop_model_resolves_person_class_and_uses_small_input(tmp_path, monkeypatch):
    from basketball_highlight import inference
    from engine.python.basketball_engine import person_candidates

    weights = tmp_path / "test.pt"
    weights.write_bytes(b"test fixture, never deserialized")
    monkeypatch.setattr(
        person_candidates,
        "PERSON_MODEL_SHA256",
        hashlib.sha256(weights.read_bytes()).hexdigest(),
    )
    seen = {}

    class Model:
        names = {7: "person", 8: "ball"}

        def predict(self, image, **kwargs):
            seen.update(kwargs)
            return [type("Result", (), {"boxes": []})()]

    monkeypatch.setattr(inference, "select_device", lambda *a: "cpu")
    monkeypatch.setattr(inference, "current_device", lambda: "cpu")
    monkeypatch.setattr(inference, "load_detector", lambda *a, **k: Model())
    assert YoloPersonCropDetector(weights).detect(np.zeros((80, 60, 3), np.uint8)) == []
    assert seen["imgsz"] == 320 and seen["classes"] == [7] and seen["rect"] is True


def test_engine_reuses_verified_model_until_weights_change(tmp_path, monkeypatch):
    from engine.python.basketball_engine import person_candidates
    from engine.python.basketball_engine.service import EngineService

    weights = tmp_path / "person.pt"
    weights.write_bytes(b"fixture")
    monkeypatch.setattr(person_candidates, "person_model_path", lambda: weights)
    loaded = []

    def load(path):
        loaded.append(path)
        return FakeDetector([])

    monkeypatch.setattr(person_candidates, "YoloPersonCropDetector", load)
    service = EngineService()
    try:
        first = service._region_person_candidates()
        assert service._region_person_candidates() is first
        assert len(loaded) == 1
        weights.write_bytes(b"changed fixture")
        assert service._region_person_candidates() is not first
        assert len(loaded) == 2
    finally:
        service.shutdown()
