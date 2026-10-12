"""Photo sphere stitching by orientation: frames rendered from a known sphere at the app's
target grid, with gyroscope drift and the wrong field of view assumed, stitch back to it."""

from __future__ import annotations

import math
from pathlib import Path

import cv2
import numpy as np
import pytest

from retail_platform.vision import photosphere
from retail_platform.vision.photosphere import Pose

FIXTURE = Path(__file__).resolve().parents[2] / "test" / "fixtures" / "screen_shelf.jpg"
TRUE_FOV = 70.0
FRAME_W, FRAME_H = 810, 1440  # portrait 16:9, as the app's camera delivers


def _scene(width: int = 2048) -> np.ndarray:
    """A textured equirectangular scene: shelf photos all around the horizon."""
    shelf = cv2.imread(str(FIXTURE))
    height = width // 2
    band = cv2.resize(shelf, (width // 4, height // 2))
    row = np.concatenate([band, cv2.flip(band, 1), band[::-1], cv2.flip(band, 0)], axis=1)
    rng = np.random.default_rng(1)
    sky = rng.integers(0, 255, (height // 4, width, 3), dtype=np.uint8)
    sky = cv2.GaussianBlur(sky, (0, 0), 3)
    return np.concatenate([sky, row, sky[::-1]], axis=0)


def _render(scene: np.ndarray, pose: Pose, fov: float = TRUE_FOV) -> np.ndarray:
    """What a phone camera at [pose] sees of [scene]."""
    height, width = scene.shape[:2]
    f = photosphere.focal(FRAME_W, FRAME_H, fov)
    x, y = np.meshgrid((np.arange(FRAME_W) + 0.5 - FRAME_W / 2) / f, -(np.arange(FRAME_H) + 0.5 - FRAME_H / 2) / f)
    rays = np.stack([x, y, np.ones_like(x)], axis=-1) @ photosphere.rotation(pose).T
    lon = np.arctan2(rays[..., 0], rays[..., 2])
    lat = np.arctan2(rays[..., 1], np.hypot(rays[..., 0], rays[..., 2]))
    mx = ((lon + np.pi) / (2 * np.pi) * width - 0.5).astype(np.float32)
    my = ((np.pi / 2 - lat) / np.pi * height - 0.5).astype(np.float32)
    return cv2.remap(scene, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_WRAP)


def _targets() -> list[Pose]:
    """The app's grid: 15 at eye level, 10 at ±40°."""
    grid = [Pose(i * 24.0, 0, 0) for i in range(15)]
    grid += [Pose(i * 36.0, 40, 0) for i in range(10)]
    grid += [Pose(i * 36.0, -40, 0) for i in range(10)]
    return grid


def _band_error(a: np.ndarray, b: np.ndarray) -> float:
    h = a.shape[0]
    band = slice(int(h * 0.3), int(h * 0.7))  # ±36° around the horizon, where the shelves are
    return float(np.mean(np.abs(a[band].astype(int) - b[band].astype(int))))


def test_stitches_back_to_the_scene_despite_drift_and_wrong_fov():
    scene = _scene()
    truth = _targets()
    frames = [_render(scene, p) for p in truth]
    # Gyroscope drift grows over the capture (4° by the end); gravity's pitch and roll are a
    # couple of degrees off on a hand-held phone.
    rng = np.random.default_rng(5)
    noisy = [Pose(p.yaw + 4.0 * i / len(truth) + rng.normal(0, 0.5), p.pitch + rng.normal(0, 2),
                  p.roll + rng.normal(0, 2)) for i, p in enumerate(truth)]
    raw = photosphere.stitch(frames, noisy, long_side_fov=62.0, width=2048, refine_poses=False)
    result = photosphere.stitch(frames, noisy, long_side_fov=62.0, width=2048)

    assert result.fov_measured
    assert abs(result.long_side_fov - TRUE_FOV) <= 1.0
    assert result.coverage > 0.8
    assert _band_error(result.image, scene) < 16
    assert _band_error(result.image, scene) < 0.6 * _band_error(raw.image, scene)


def test_bundle_adjustment_recovers_every_orientation():
    scene = _scene()
    truth = _targets()
    frames = [photosphere._resize(_render(scene, p), 800) for p in truth]
    rng = np.random.default_rng(7)
    noisy = [Pose(p.yaw + 4.0 * i / len(truth), p.pitch + rng.normal(0, 2), p.roll + rng.normal(0, 2))
             for i, p in enumerate(truth)]
    fov, ring, _, _ = photosphere.refine(frames, noisy, 62.0)
    poses, fov, pairs = photosphere.bundle_adjust(frames, ring, fov)
    assert pairs > 30
    assert abs(fov - TRUE_FOV) <= 1.0
    offset = poses[0].yaw - truth[0].yaw
    for got, want in zip(poses, truth):
        assert abs(got.yaw - offset - want.yaw) < 1.0
        assert abs(got.pitch - want.pitch) < 1.0
        assert abs(got.roll - want.roll) < 1.0


def test_handheld_roll_is_undone():
    scene = _scene()
    truth = [Pose(i * 24.0, 0, (-1) ** i * 6.0) for i in range(15)]
    frames = [_render(scene, p) for p in truth]
    result = photosphere.stitch(frames, truth, long_side_fov=TRUE_FOV, width=2048, refine_poses=False)
    assert _band_error(result.image, scene) < 20


def test_view_boxes_map_back_to_the_sphere():
    # The centre of the view looking at heading 90° is longitude 90°, on the horizon.
    ex, ey, ew, eh, relative = photosphere.view_box_to_equirect((0.45, 0.45, 0.1, 0.1), 90.0)
    assert ex + ew / 2 == pytest.approx((90 + 180) / 360, abs=0.002)
    assert ey + eh / 2 == pytest.approx(0.5, abs=0.002)
    assert relative == pytest.approx(0.0, abs=0.1)
    # A box at the right edge is ~45° right of the view's heading.
    *_, relative = photosphere.view_box_to_equirect((0.95, 0.45, 0.05, 0.1), 0.0)
    assert relative == pytest.approx(math.degrees(math.atan(0.95 * math.tan(math.radians(50)))), abs=0.5)


def test_rendered_view_matches_a_frame_from_the_same_heading():
    scene = _scene()
    view = photosphere.render_view(scene, 120.0, fov=60.0, side=400)
    f = 200 / math.tan(math.radians(30))
    x, y = np.meshgrid((np.arange(400) + 0.5 - 200) / f, -(np.arange(400) + 0.5 - 200) / f)
    rays = np.stack([x, y, np.ones_like(x)], axis=-1) @ photosphere.rotation(Pose(120.0, 0, 0)).T
    lon = np.arctan2(rays[..., 0], rays[..., 2])
    assert float(np.degrees(lon[200, 200])) == pytest.approx(120.0, abs=0.3)
    assert view.shape == (400, 400, 3)
