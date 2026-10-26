import pytest

from basketball_highlight.roi import effective_crop_scale


@pytest.mark.parametrize("roi, requested, expected", [
    ((380, 8, 909, 413), 4, 640 / 529),
    ((760, 16, 1818, 826), 2, 1.0),
    ((0, 0, 200, 200), 4, 3.2),
    ((0, 0, 200, 200), 1, 1.0),
    ((0, 0, 640, 480), 8, 1.0),
    ((0, 0, 641, 480), 8, 1.0),
])
def test_effective_crop_scale_clamps_to_model_input(roi, requested, expected):
    assert effective_crop_scale(roi, requested) == pytest.approx(expected)


@pytest.mark.parametrize("roi, requested", [
    ((0, 0, 0, 0), 4),
    ((10, 10, 10, 20), 4),
    ((0, 0, 200, 200), 0),
])
def test_effective_crop_scale_rejects_invalid_input(roi, requested):
    with pytest.raises(ValueError, match="ROI_INPUT_INVALID"):
        effective_crop_scale(roi, requested)
