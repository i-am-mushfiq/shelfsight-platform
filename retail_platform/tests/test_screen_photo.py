"""Clean-up for photos of a screen (no neural networks needed)."""

from __future__ import annotations

from pathlib import Path

import cv2
import numpy as np

from retail_platform.tests.screen_sim import photograph_screen
from retail_platform.vision.screen_photo import (
    clean, find_screen, grid_score, is_screen_photo, normalise_colours, rectify, remove_moire,
)

SHELF = Path(__file__).resolve().parents[2] / "test_assets" / "shelf-square-low-1-of-12.png"


def _shelf() -> np.ndarray:
    return cv2.resize(cv2.imread(str(SHELF)), (900, 600))


def test_photo_of_a_screen_is_recognised_and_a_plain_image_is_not():
    for seed, kind in ((0, "lcd"), (1, "crt"), (2, "lcd")):
        assert is_screen_photo(photograph_screen(_shelf(), np.random.default_rng(seed), kind))
    assert grid_score(_shelf()) < 45


def test_screen_outline_is_found_and_straightened():
    photo = np.full((900, 1200, 3), 40, np.uint8)
    corners = np.float32([[260, 180], [980, 220], [950, 720], [230, 690]])
    warp = cv2.getPerspectiveTransform(np.float32([[0, 0], [900, 0], [900, 600], [0, 600]]), corners)
    cv2.fillConvexPoly(photo, corners.astype(np.int32) + [[-12, -12], [12, -12], [12, 12], [-12, 12]], (15, 15, 15))
    screen = cv2.warpPerspective(_shelf(), warp, (1200, 900))
    mask = cv2.warpPerspective(np.full((600, 900), 255, np.uint8), warp, (1200, 900)) > 0
    photo[mask] = screen[mask]
    found = find_screen(photo)
    assert found is not None and np.abs(found - corners).max() < 40  # dark content at a corner blends with the bezel
    straight, back = rectify(photo, found)
    assert abs(straight.shape[1] / straight.shape[0] - 1.5) < 0.15
    # A box in the straightened screen maps back onto the tilted screen in the photo.
    cleaned = clean(photo, rectify_screen=True, colours=False, moire=False)
    assert "screen" in cleaned.steps
    box, outline = cleaned.box_to_original((0.0, 0.0, 1.0, 1.0))
    assert np.abs(np.array(outline) * [1200, 900] - corners).max() < 40
    assert 0.15 < box[0] < 0.25 and 0.75 < box[0] + box[2] < 0.85


def test_colour_cast_is_removed_and_moire_smoothed():
    shelf = normalise_colours(_shelf())  # the reference: a cast is undone up to the per-channel stretch
    cast = np.clip(shelf.astype(np.float32) * [1.25, 1.0, 0.75] * 0.7 + 40, 0, 255).astype(np.uint8)
    fixed = normalise_colours(cast)
    assert np.abs(fixed.astype(np.float32) - shelf).mean() < 6
    assert np.abs(cast.astype(np.float32) - shelf).mean() > 25
    stripes = shelf.copy()
    stripes[:, ::3, 2] = 255  # a red subpixel column pattern
    assert remove_moire(stripes)[:, :, 2].astype(np.float32).std(axis=1).mean() < \
        stripes[:, :, 2].astype(np.float32).std(axis=1).mean()
