"""Test helper: renders an image as a phone photo of a monitor: subpixel grid or CRT scanlines,
room, aliasing moire from the camera resample, colour cast, glare, noise, JPEG."""
import sys
from pathlib import Path

import cv2
import numpy as np


def photograph_screen(img: np.ndarray, rng: np.random.Generator, kind: str = "lcd") -> np.ndarray:
    h, w = img.shape[:2]
    scale = 3
    # Screen: each image pixel becomes a 3x3 block of R, G, B subpixel columns (LCD) or a
    # phosphor triad with dark scanlines (CRT).
    screen = cv2.resize(img, (w * scale, h * scale), interpolation=cv2.INTER_NEAREST).astype(np.float32)
    mask = np.full((scale, scale, 3), 0.25, np.float32)
    for c, ch in enumerate((2, 1, 0)):  # BGR order: R, G, B columns
        mask[:, c, ch] = 1.0
    if kind == "crt":
        mask[scale - 1, :, :] *= 0.25  # scanline gap
        screen = cv2.GaussianBlur(screen, (3, 3), 0)  # phosphor bloom
    screen *= np.tile(mask, (h, w, 1)) * 1.6
    screen = np.clip(screen, 0, 255)
    sh, sw = screen.shape[:2]
    # Monitor in a dark room, photographed at an angle.
    bezel = int(0.04 * sw)
    canvas_w, canvas_h = int(sw * 1.35), int(sh * 1.45)
    room = np.full((canvas_h, canvas_w, 3), rng.uniform(25, 70), np.float32)
    room += rng.normal(0, 6, room.shape)
    ox, oy = (canvas_w - sw) // 2, (canvas_h - sh) // 2
    cv2.rectangle(room, (ox - bezel, oy - bezel), (ox + sw + bezel, oy + sh + bezel), (18, 18, 20), -1)
    room[oy:oy + sh, ox:ox + sw] = screen
    tilt = 0.06 * sw
    src = np.float32([[0, 0], [canvas_w, 0], [canvas_w, canvas_h], [0, canvas_h]])
    jitter = rng.uniform(-tilt, tilt, (4, 2)).astype(np.float32)
    dst = src + jitter
    rot = cv2.getRotationMatrix2D((canvas_w / 2, canvas_h / 2), rng.uniform(-4, 4), 1.0)
    homography = np.vstack([rot, [0, 0, 1]]) @ cv2.getPerspectiveTransform(src, dst)
    room = cv2.warpPerspective(room, homography, (canvas_w, canvas_h), borderValue=(30, 30, 30))
    # Phone camera: resampled to 1600 px without anti-aliasing (this is what makes moire).
    out_w = 1600
    out_h = int(canvas_h * out_w / canvas_w)
    photo = cv2.resize(room, (out_w, out_h), interpolation=cv2.INTER_LINEAR)
    # White balance / exposure of a screen under a phone's auto settings: bluish, lifted blacks.
    cast = np.array([rng.uniform(1.05, 1.25), rng.uniform(0.95, 1.05), rng.uniform(0.8, 0.95)], np.float32)
    photo = photo * cast
    photo = 255 * (np.clip(photo, 0, 255) / 255) ** rng.uniform(0.8, 1.1)
    photo = photo * rng.uniform(0.8, 1.0) + rng.uniform(5, 25)
    # Glare: a soft bright blob.
    yy, xx = np.mgrid[0:out_h, 0:out_w]
    cx, cy = rng.uniform(0.2, 0.8) * out_w, rng.uniform(0.2, 0.8) * out_h
    glare = np.exp(-(((xx - cx) ** 2 + (yy - cy) ** 2) / (2 * (0.18 * out_w) ** 2)))
    photo += (glare * rng.uniform(40, 90))[:, :, None]
    photo += rng.normal(0, 4, photo.shape)
    photo = np.clip(photo, 0, 255).astype(np.uint8)
    if rng.random() < 0.5:
        k = int(rng.integers(3, 7))
        kernel = np.zeros((k, k), np.float32)
        kernel[k // 2, :] = 1 / k
        photo = cv2.filter2D(photo, -1, kernel)  # slight hand shake
    ok, jpg = cv2.imencode(".jpg", photo, [cv2.IMWRITE_JPEG_QUALITY, 75])
    return cv2.imdecode(jpg, cv2.IMREAD_COLOR)


