"""360° photo sphere: frames taken while the officer turns on the spot, stitched into one
panorama that is analysed like any shelf photo and shown in a 360° viewer.

The app records the compass-free yaw of each frame from the gyroscope; frames are stitched
in that order with OpenCV's panorama stitcher (spherical warping). When stitching fails
(too little overlap, moving people, blank walls) the frames are placed side by side so the
visit still has its evidence; the capture says which happened.
"""

from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

FRAME_SIDE = 1000          # frames are stitched at this size: quality vs. seconds on a laptop
MAX_PANORAMA_WIDTH = 9000
ASSUMED_HFOV = 60.0        # degrees a phone frame covers horizontally (portrait main camera)


@dataclass(slots=True)
class Sphere:
    image: np.ndarray
    stitched: bool
    frames: int
    yaw_span: float | None
    frames_joined: int
    horizontal_degrees: float
    vertical_degrees: float
    note: str | None = None

    def metadata(self) -> dict:
        return {"kind": "sphere", "frames": self.frames, "frames_joined": self.frames_joined,
                "stitched": self.stitched, "yaw_span": self.yaw_span,
                "horizontal_degrees": round(self.horizontal_degrees, 1),
                "vertical_degrees": round(self.vertical_degrees, 1), "note": self.note}


def _resize(image: np.ndarray, side: int) -> np.ndarray:
    scale = side / max(image.shape[:2])
    return cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA) if scale < 1 else image


def _crop_black(image: np.ndarray) -> np.ndarray:
    """Trim the empty border the warp leaves around a stitched panorama."""
    mask = (cv2.cvtColor(image, cv2.COLOR_BGR2GRAY) > 0).astype(np.uint8)
    rows, cols = np.where(mask.mean(axis=1) > 0.9)[0], np.where(mask.mean(axis=0) > 0.6)[0]
    if len(rows) < 10 or len(cols) < 10:
        return image
    return image[rows[0]:rows[-1] + 1, cols[0]:cols[-1] + 1]


def stitch(frames: list[np.ndarray], yaws: list[float] | None = None) -> Sphere:
    if len(frames) < 2:
        raise ValueError("A photo sphere needs at least two frames")
    if yaws and len(yaws) == len(frames):
        order = sorted(range(len(frames)), key=lambda i: yaws[i])
        frames = [frames[i] for i in order]
        yaws = [yaws[i] for i in order]
        yaw_span = float(max(yaws) - min(yaws))
    else:
        yaws, yaw_span = None, None
    frames = [_resize(f, FRAME_SIDE) for f in frames]
    stitcher = cv2.Stitcher_create(cv2.Stitcher_PANORAMA)
    stitcher.setPanoConfidenceThresh(0.6)  # default 1.0 drops frames of plain or repetitive shelves
    try:
        status, panorama = stitcher.stitch(frames)
    except cv2.error:
        status, panorama = -1, None
    stitched = status == cv2.Stitcher_OK and panorama is not None
    note = None
    joined = len(frames)
    if stitched:
        panorama = _crop_black(panorama)
        joined = len(stitcher.component())
        if joined < len(frames):
            # The stitcher keeps only the frames it can connect; say so rather than hide it.
            note = f"{joined} of {len(frames)} frames could be joined; the rest overlapped too little."
            if yaw_span is not None:
                yaw_span = yaw_span * (joined - 1) / max(1, len(frames) - 1)
    else:
        height = min(f.shape[0] for f in frames)
        panorama = cv2.hconcat([cv2.resize(f, (round(f.shape[1] * height / f.shape[0]), height)) for f in frames])
        note = "Frames could not be stitched (too little overlap or movement); shown side by side."
    if panorama.shape[1] > MAX_PANORAMA_WIDTH:
        panorama = _resize(panorama, MAX_PANORAMA_WIDTH)
    height, width = panorama.shape[:2]
    covered = (yaw_span + ASSUMED_HFOV) if yaw_span is not None else ASSUMED_HFOV * len(frames) * 0.7
    horizontal = min(360.0, covered)
    vertical = min(170.0, horizontal * height / width)
    return Sphere(panorama, stitched, len(frames), yaw_span, joined, horizontal, vertical, note)
