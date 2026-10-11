"""Clean-up for photos taken of a screen (a demo shelf image shown on a monitor or CRT).

A phone photo of a screen differs from a photo of a shelf in ways that hurt recognition: the
screen is a tilted quadrilateral inside a dark bezel and room; colours are washed out and cast
(usually blue) by the screen's backlight and the phone's white balance; and the screen's pixel
grid or scanlines beat against the camera's sensor as moire bands. The steps here undo that:

  * rectify — find the screen (a bright convex quadrilateral clearly brighter than its border)
              and warp it to a straight rectangle; points map back to the original photo;
  * colours — stretch each channel between its 1st and 99th percentile (removes the cast and
              restores contrast; nearly a no-op on a well-exposed photo);
  * moire   — moire and subpixel patterns are mostly fine, coloured texture: the colour
              channels are blurred strongly and the brightness channel lightly.

Each step can be turned off; `clean` reports which ran. `is_screen_photo` tells whether a photo
is of a screen at all (a screen outline, or the regular spectral peaks of a pixel grid), so the
recogniser can use thresholds suited to it.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import cv2
import numpy as np


@dataclass(slots=True)
class Cleaned:
    image: np.ndarray
    steps: list[str] = field(default_factory=list)
    # Homography from the cleaned image back to the original photo (None: same coordinates).
    to_original: np.ndarray | None = None
    original_size: tuple[int, int] = (0, 0)   # width, height

    def box_to_original(self, box: tuple[float, float, float, float]
                        ) -> tuple[tuple[float, float, float, float], list[tuple[float, float]]]:
        """A normalised box in the cleaned image -> normalised box and outline in the original."""
        if self.to_original is None:
            return box, []
        height, width = self.image.shape[:2]
        x, y, w, h = box
        corners = np.float32([[x, y], [x + w, y], [x + w, y + h], [x, y + h]]) * [width, height]
        mapped = cv2.perspectiveTransform(corners.reshape(-1, 1, 2), self.to_original).reshape(-1, 2)
        ow, oh = self.original_size
        mapped = mapped / [ow, oh]
        x0, y0 = mapped.min(axis=0).clip(0, 1)
        x1, y1 = mapped.max(axis=0).clip(0, 1)
        return (float(x0), float(y0), float(x1 - x0), float(y1 - y0)), [(float(px), float(py)) for px, py in mapped]


def _order(points: np.ndarray) -> np.ndarray:
    """Corners as top-left, top-right, bottom-right, bottom-left."""
    s, d = points.sum(axis=1), np.diff(points, axis=1).ravel()
    return np.float32([points[s.argmin()], points[d.argmin()], points[s.argmax()], points[d.argmax()]])


def find_screen(image: np.ndarray) -> np.ndarray | None:
    """Corners of a screen in the photo, or None when the photo is not of a screen (or it fills it)."""
    height, width = image.shape[:2]
    scale = 800 / max(height, width)
    small = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA) if scale < 1 else image
    scale = min(scale, 1.0)
    gray = cv2.GaussianBlur(cv2.cvtColor(small, cv2.COLOR_BGR2GRAY), (7, 7), 0)
    _, bright = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    bright = cv2.morphologyEx(bright, cv2.MORPH_CLOSE, np.ones((25, 25), np.uint8))
    contours, _ = cv2.findContours(bright, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None
    contour = max(contours, key=cv2.contourArea)
    area = cv2.contourArea(contour)
    frame = small.shape[0] * small.shape[1]
    if not 0.2 * frame <= area <= 0.95 * frame:
        return None
    hull = cv2.convexHull(contour)
    hull_area = cv2.contourArea(hull)
    # Candidate outlines: polygon fits of the hull at several tolerances, and its tightest rectangle.
    candidates = [cv2.boxPoints(cv2.minAreaRect(hull)).astype(np.float32)]
    for epsilon in (0.02, 0.03, 0.05, 0.08):
        approx = cv2.approxPolyDP(hull, epsilon * cv2.arcLength(hull, True), True)
        if len(approx) == 4:
            candidates.append(approx.reshape(4, 2).astype(np.float32))
    best, best_contrast = None, 30.0  # a screen is clearly brighter than the bezel around it
    for quad in candidates:
        if not 0.8 * hull_area <= cv2.contourArea(quad) <= 1.2 * hull_area:
            continue
        inside = np.zeros(gray.shape, np.uint8)
        cv2.fillConvexPoly(inside, quad.astype(np.int32), 255)
        ring = cv2.dilate(inside, np.ones((31, 31), np.uint8)) & ~inside
        if not ring.any():
            continue
        border = gray[ring > 0]
        contrast = float(gray[inside > 0].mean()) - float(border.mean())
        # A bezel is dark and plain; a dark shelf around a bright one is busy with products.
        if border.mean() > 80 or border.std() > 28:
            continue
        if contrast > best_contrast:
            best, best_contrast = quad, contrast
    if best is None:
        return None
    quad = best
    return _order(quad / scale)


def rectify(image: np.ndarray, corners: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """The screen warped to a straight rectangle, and the homography back to the photo."""
    tl, tr, br, bl = corners
    width = int(max(np.linalg.norm(tr - tl), np.linalg.norm(br - bl)))
    height = int(max(np.linalg.norm(bl - tl), np.linalg.norm(br - tr)))
    target = np.float32([[0, 0], [width, 0], [width, height], [0, height]])
    forward = cv2.getPerspectiveTransform(corners, target)
    return cv2.warpPerspective(image, forward, (width, height), flags=cv2.INTER_LINEAR), np.linalg.inv(forward)


def normalise_colours(image: np.ndarray) -> np.ndarray:
    """Per-channel stretch from the 1st to the 99th percentile (white balance + contrast)."""
    out = np.empty_like(image)
    for channel in range(3):
        low, high = np.percentile(image[:, :, channel], (1, 99))
        if high - low < 20:
            out[:, :, channel] = image[:, :, channel]
            continue
        stretched = (image[:, :, channel].astype(np.float32) - low) * (255.0 / (high - low))
        out[:, :, channel] = np.clip(stretched, 0, 255).astype(np.uint8)
    return out


def remove_moire(image: np.ndarray) -> np.ndarray:
    """Blur colour strongly and brightness lightly: moire is fine, mostly coloured texture."""
    side = max(image.shape[:2])
    ycrcb = cv2.cvtColor(image, cv2.COLOR_BGR2YCrCb)
    chroma_sigma = max(1.5, side / 600)
    luma_sigma = max(0.8, side / 1600)
    ycrcb[:, :, 0] = cv2.GaussianBlur(ycrcb[:, :, 0], (0, 0), luma_sigma)
    ycrcb[:, :, 1] = cv2.GaussianBlur(ycrcb[:, :, 1], (0, 0), chroma_sigma)
    ycrcb[:, :, 2] = cv2.GaussianBlur(ycrcb[:, :, 2], (0, 0), chroma_sigma)
    return cv2.cvtColor(ycrcb, cv2.COLOR_YCrCb2BGR)


def clean(image: np.ndarray, rectify_screen: bool = True, colours: bool = True, moire: bool = True) -> Cleaned:
    height, width = image.shape[:2]
    result = Cleaned(image, original_size=(width, height))
    if rectify_screen:
        corners = find_screen(image)
        if corners is not None:
            result.image, result.to_original = rectify(image, corners)
            result.steps.append("screen")
    if colours:
        result.image = normalise_colours(result.image)
        result.steps.append("colours")
    if moire:
        result.image = remove_moire(result.image)
        result.steps.append("moire")
    return result


def grid_score(image: np.ndarray) -> float:
    """How strongly a regular fine pattern (a screen's pixel grid, scanlines, moire) stands out in
    the photo's spectrum: the brightest high-frequency peak over the band's median. Ordinary
    photos score about 15-50, photos of screens 25-150 (most of them are found by their outline)."""
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY).astype(np.float32)
    height, width = gray.shape
    side = min(height, width, 1024)
    top, left = (height - side) // 2, (width - side) // 2
    patch = gray[top:top + side, left:left + side]
    patch = (patch - cv2.GaussianBlur(patch, (0, 0), 3)) * np.outer(np.hanning(side), np.hanning(side))
    spectrum = np.abs(np.fft.fftshift(np.fft.fft2(patch)))
    yy, xx = np.mgrid[0:side, 0:side] - side // 2
    radius = np.hypot(xx, yy) / (side / 2)
    band = spectrum[(radius > 0.15) & (radius < 0.95)]
    return float(np.percentile(band, 99.99) / max(1e-6, float(np.median(band))))


def is_screen_photo(image: np.ndarray, grid_threshold: float = 60.0) -> bool:
    return find_screen(image) is not None or grid_score(image) >= grid_threshold
