"""Photo sphere the way Google's Street View capture builds one.

The app guides the officer onto a grid of targets (a ring at eye level, one above, one below)
and records the camera's orientation for every frame: yaw (heading, from the gyroscope, growing
to the right), pitch (up is positive) and roll (from gravity). Each frame is then projected onto
a 360° × 180° equirectangular image by that orientation, so frames never "collapse" the way
feature-only stitching does on repetitive shelves. Feature matching is used only to refine:

* the lens's field of view, measured from neighbouring frames of the eye-level ring;
* the gyroscope's yaw drift, measured the same way and closed around the full turn.

Recognition runs on flat (rectilinear) views cut from the sphere around the horizon, so the
models see undistorted packs, and each box is mapped back onto the sphere.

Coordinates: camera x right, y up, z forward; world y up, longitude 0 at the first frame's
heading, growing to the right; equirectangular x = (lon + 180) / 360, y = (90 - lat) / 180.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import cv2
import numpy as np

DEFAULT_LONG_SIDE_FOV = 70.0   # degrees across a phone photo's long side (main camera)
EQUIRECT_WIDTH = 4096
FRAME_SIDE = 1400              # frames are projected at this size
VIEW_YAWS = (0.0, 90.0, 180.0, 270.0)
VIEW_FOV = 100.0               # each recognition view covers 100° × 100°
VIEW_SIDE = 1600


@dataclass(slots=True)
class Pose:
    yaw: float
    pitch: float
    roll: float


@dataclass(slots=True)
class PhotoSphere:
    image: np.ndarray
    frames: int
    long_side_fov: float
    fov_measured: bool
    yaw_corrected: bool
    coverage: float
    notes: list[str] = field(default_factory=list)

    def metadata(self) -> dict:
        return {"kind": "sphere", "projection": "equirectangular", "frames": self.frames,
                "frames_joined": self.frames, "stitched": True, "yaw_span": 360.0,
                "horizontal_degrees": 360.0, "vertical_degrees": 180.0,
                "long_side_fov": round(float(self.long_side_fov), 1), "fov_measured": bool(self.fov_measured),
                "yaw_corrected": bool(self.yaw_corrected), "coverage": round(float(self.coverage), 3),
                "note": " ".join(self.notes) or None}


def rotation(pose: Pose) -> np.ndarray:
    """Camera-to-world rotation: roll about the view axis, then pitch, then yaw."""
    h, p, r = (math.radians(v) for v in (pose.yaw, pose.pitch, pose.roll))
    roll = np.array([[math.cos(r), math.sin(r), 0], [-math.sin(r), math.cos(r), 0], [0, 0, 1]])
    pitch = np.array([[1, 0, 0], [0, math.cos(p), math.sin(p)], [0, -math.sin(p), math.cos(p)]])
    yaw = np.array([[math.cos(h), 0, math.sin(h)], [0, 1, 0], [-math.sin(h), 0, math.cos(h)]])
    return yaw @ pitch @ roll


def focal(width: int, height: int, long_side_fov: float) -> float:
    return max(width, height) / 2 / math.tan(math.radians(long_side_fov) / 2)


def _resize(image: np.ndarray, side: int) -> np.ndarray:
    scale = side / max(image.shape[:2])
    return cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA) if scale < 1 else image


# --- refinement from the eye-level ring ---------------------------------------------------------

def _matches(a: np.ndarray, b: np.ndarray) -> tuple[np.ndarray, np.ndarray] | None:
    orb = cv2.ORB_create(1500)
    ka, da = orb.detectAndCompute(cv2.cvtColor(a, cv2.COLOR_BGR2GRAY), None)
    kb, db = orb.detectAndCompute(cv2.cvtColor(b, cv2.COLOR_BGR2GRAY), None)
    if da is None or db is None or len(ka) < 30 or len(kb) < 30:
        return None
    pairs = cv2.BFMatcher(cv2.NORM_HAMMING).knnMatch(da, db, k=2)
    good = [m for m, *rest in pairs if rest and m.distance < 0.75 * rest[0].distance]
    if len(good) < 25:
        return None
    pa = np.float32([ka[m.queryIdx].pt for m in good])
    pb = np.float32([kb[m.trainIdx].pt for m in good])
    _, inliers = cv2.findHomography(pa, pb, cv2.RANSAC, 4.0)
    if inliers is None or inliers.sum() < 20:
        return None
    keep = inliers.ravel().astype(bool)
    return pa[keep], pb[keep]


def _bearings(points: np.ndarray, f: float, cx: float, cy: float, pose: Pose) -> np.ndarray:
    """World longitude (degrees) of image points seen from [pose] with focal [f]."""
    rays = np.stack([(points[:, 0] - cx) / f, -(points[:, 1] - cy) / f, np.ones(len(points))], axis=1)
    world = rays @ rotation(Pose(0.0, pose.pitch, pose.roll)).T
    return np.degrees(np.arctan2(world[:, 0], world[:, 2]))


def refine(frames: list[np.ndarray], poses: list[Pose], long_side_fov: float) -> tuple[float, list[Pose], bool, bool]:
    """Field of view and drift-corrected yaws from neighbouring eye-level frames."""
    ring = sorted((i for i, p in enumerate(poses) if abs(p.pitch) < 20), key=lambda i: poses[i].yaw)
    if len(ring) < 3:
        return long_side_fov, poses, False, False
    pairs = []
    for a, b in zip(ring, ring[1:] + ring[:1]):
        gyro = (poses[b].yaw - poses[a].yaw) % 360
        if not 5 < gyro < 60:
            continue
        found = _matches(frames[a], frames[b])
        if found is not None:
            pairs.append((a, b, gyro, found))
    if not pairs:
        return long_side_fov, poses, False, False

    h, w = frames[0].shape[:2]
    cx, cy = w / 2, h / 2

    def measured(fov: float, a: int, b: int, pts: tuple[np.ndarray, np.ndarray]) -> float:
        f = focal(w, h, fov)
        return float(np.median((_bearings(pts[0], f, cx, cy, poses[a]) - _bearings(pts[1], f, cx, cy, poses[b])) % 360))

    # The field of view that makes the measured turn between frames match the gyroscope's
    # (the gyroscope is accurate over a few degrees; it drifts over a whole turn).
    candidates = np.arange(50.0, 90.5, 0.5)
    errors = [np.median([min(abs(measured(fov, a, b, pts) - gyro), 10.0) for a, b, gyro, pts in pairs])
              for fov in candidates]
    best = float(candidates[int(np.argmin(errors))])
    fov_measured = len(pairs) >= 2 and min(errors) < 2.0
    fov = best if fov_measured else long_side_fov

    # Yaw: chain the measured turns around the ring and close the loop to 360°.
    # A measured step far from the gyroscope's is a false match (repetitive shelves): the
    # gyroscope is trusted over one step, the matches only for its small error.
    deltas = {}
    for a, b, gyro, pts in pairs:
        step = measured(fov, a, b, pts)
        if abs(step - gyro) <= 4.0:
            deltas[(a, b)] = step
    steps, all_measured = [], True
    for a, b in zip(ring, ring[1:] + ring[:1]):
        gyro = (poses[b].yaw - poses[a].yaw) % 360
        all_measured &= (a, b) in deltas
        steps.append(deltas.get((a, b), gyro))
    total = sum(steps)
    # Close the loop only when every step was measured: an unmeasured gyroscope step carries
    # the whole turn's drift, and spreading it would put the drift back.
    if all_measured and abs(total - 360) < 40:
        steps = [s * 360 / total for s in steps]
    corrected = {ring[0]: poses[ring[0]].yaw}
    for i, (a, b) in enumerate(zip(ring, ring[1:])):
        corrected[b] = corrected[a] + steps[i]
    # Frames off the ring take the correction of the nearest ring frames by heading.
    ring_old = np.array([poses[i].yaw for i in ring])
    ring_fix = np.array([corrected[i] - poses[i].yaw for i in ring])
    order = np.argsort(ring_old)
    xs = np.concatenate([ring_old[order] - 360, ring_old[order], ring_old[order] + 360])
    ys = np.tile(ring_fix[order], 3)
    new = [Pose(corrected[i] if i in corrected else p.yaw + float(np.interp(p.yaw % 360, xs, ys)), p.pitch, p.roll)
           for i, p in enumerate(poses)]
    return fov, new, fov_measured, True


# --- bundle adjustment over every overlapping pair ----------------------------------------------

def _rotations(params: np.ndarray) -> np.ndarray:
    """(n, 3) yaw/pitch/roll in degrees -> (n, 3, 3) camera-to-world rotations."""
    h, p, r = np.radians(params[:, 0]), np.radians(params[:, 1]), np.radians(params[:, 2])
    ch, sh, cp, sp, cr, sr = np.cos(h), np.sin(h), np.cos(p), np.sin(p), np.cos(r), np.sin(r)
    n = len(params)
    yaw = np.zeros((n, 3, 3))
    yaw[:, 0, 0], yaw[:, 0, 2], yaw[:, 1, 1], yaw[:, 2, 0], yaw[:, 2, 2] = ch, sh, 1, -sh, ch
    pitch = np.zeros((n, 3, 3))
    pitch[:, 0, 0], pitch[:, 1, 1], pitch[:, 1, 2], pitch[:, 2, 1], pitch[:, 2, 2] = 1, cp, sp, -sp, cp
    roll = np.zeros((n, 3, 3))
    roll[:, 0, 0], roll[:, 0, 1], roll[:, 1, 0], roll[:, 1, 1], roll[:, 2, 2] = cr, sr, -sr, cr, 1
    return yaw @ pitch @ roll


def _huber(r: np.ndarray, k: float = 3.0) -> np.ndarray:
    """Square roots of Huber weights: matches far off (false or moving) count less."""
    return np.sqrt(np.where(np.abs(r) > k, k / np.maximum(np.abs(r), 1e-9), 1.0))


def bundle_adjust(frames: list[np.ndarray], poses: list[Pose], long_side_fov: float,
                  fit_fov: bool = True) -> tuple[list[Pose], float, int]:
    """Orientations (and the field of view) that make every matched point between overlapping
    frames point the same way, as panorama stitchers do. The phone's own orientation is kept
    as a weak prior, so frames with no matches stay where the phone said.
    Returns the poses, the field of view and the number of matched pairs used."""
    n = len(frames)
    h, w = frames[0].shape[:2]
    dirs = np.array([rotation(p)[:, 2] for p in poses])
    pairs = []
    for i in range(n):
        for j in range(i + 1, n):
            if math.degrees(math.acos(float(np.clip(dirs[i] @ dirs[j], -1, 1)))) > long_side_fov * 0.8:
                continue
            found = _matches(frames[i], frames[j])
            if found is None:
                continue
            a, b = found
            if len(a) > 120:
                keep = np.linspace(0, len(a) - 1, 120).astype(int)
                a, b = a[keep], b[keep]
            pairs.append((i, j, a, b))
    if not pairs:
        return poses, long_side_fov, 0
    # Whole pairs can match falsely (repetitive shelves) and still agree among themselves, so
    # pairs are checked against the phone's orientation first and against the solution after.
    pairs = _consistent(pairs, poses, w, h, long_side_fov, 5.0)
    if pairs:
        poses, long_side_fov = _solve(pairs, poses, w, h, long_side_fov, fit_fov)
        pairs = _consistent(pairs, poses, w, h, long_side_fov, 1.0)
        if pairs:
            poses, long_side_fov = _solve(pairs, poses, w, h, long_side_fov, fit_fov)
    return poses, float(np.clip(long_side_fov, 45, 95)), len(pairs)


def _pair_disagreement(a: np.ndarray, b: np.ndarray, pa: Pose, pb: Pose, w: int, h: int, fov: float) -> float:
    """Median angle (degrees) between where two frames say their matched points are."""
    f = focal(w, h, fov)

    def rays(points: np.ndarray) -> np.ndarray:
        r = np.stack([(points[:, 0] - w / 2) / f, -(points[:, 1] - h / 2) / f, np.ones(len(points))], axis=1)
        return r / np.linalg.norm(r, axis=1, keepdims=True)

    dots = np.einsum('ni,ni->n', rays(a) @ rotation(pa).T, rays(b) @ rotation(pb).T)
    return float(np.degrees(np.median(np.arccos(np.clip(dots, -1, 1)))))


def _consistent(pairs: list, poses: list[Pose], w: int, h: int, fov: float, limit: float) -> list:
    return [(i, j, a, b) for i, j, a, b in pairs
            if _pair_disagreement(a, b, poses[i], poses[j], w, h, fov) <= limit]


def _solve(pairs: list, poses: list[Pose], w: int, h: int, long_side_fov: float,
           fit_fov: bool) -> tuple[list[Pose], float]:
    n = len(poses)
    ii = np.concatenate([np.full(len(a), i) for i, _, a, _ in pairs])
    jj = np.concatenate([np.full(len(a), j) for _, j, a, _ in pairs])
    pa = np.concatenate([a for _, _, a, _ in pairs])
    pb = np.concatenate([b for _, _, _, b in pairs])
    prior = np.array([[p.yaw, p.pitch, p.roll] for p in poses], float)
    f0 = focal(w, h, long_side_fov)

    def unpack(x: np.ndarray) -> tuple[np.ndarray, float]:
        params = prior.copy()
        params[1:] = x[:3 * (n - 1)].reshape(n - 1, 3)
        params[0, 1:] = x[3 * (n - 1):3 * (n - 1) + 2]   # frame 0 keeps its yaw (the gauge)
        return params, float(x[-1])

    def rays(points: np.ndarray, f: float) -> np.ndarray:
        r = np.stack([(points[:, 0] - w / 2) / f, -(points[:, 1] - h / 2) / f, np.ones(len(points))], axis=1)
        return r / np.linalg.norm(r, axis=1, keepdims=True)

    def residuals(x: np.ndarray) -> np.ndarray:
        params, fov = unpack(x)
        f = focal(w, h, fov)
        rot = _rotations(params)
        wa = np.einsum("nij,nj->ni", rot[ii], rays(pa, f))
        wb = np.einsum("nij,nj->ni", rot[jj], rays(pb, f))
        # In pixels at the starting focal length: scaling by the current one would let a wider
        # field of view shrink every error and run away.
        match = ((wa - wb) * f0).ravel()
        # Weak priors (pixels per degree of disagreement): gravity's pitch and roll are good to
        # a degree or two; the gyroscope's yaw drifts, so it is held more loosely.
        deg = f0 * math.pi / 180
        drift = params - prior
        drift[:, 0] = (drift[:, 0] + 180) % 360 - 180
        weak = np.concatenate([drift[:, 0] * deg * 0.02, drift[:, 1] * deg * 0.03, drift[:, 2] * deg * 0.03])
        fov_prior = [(fov - long_side_fov) * deg * (0.01 if fit_fov else 10.0)]
        return np.concatenate([match, weak, fov_prior])

    # Levenberg–Marquardt with a numerical Jacobian (about a hundred parameters).
    x = np.concatenate([prior[1:].ravel(), prior[0, 1:], [long_side_fov]])
    lam = 1e-2
    for _ in range(25):
        r = residuals(x)
        sw = _huber(r)
        eps = 1e-3
        jac = np.empty((len(r), len(x)))
        for k in range(len(x)):
            step = np.zeros_like(x)
            step[k] = eps
            jac[:, k] = (residuals(x + step) - r) / eps
        jw, rw = jac * sw[:, None], r * sw
        a, g = jw.T @ jw, jw.T @ rw
        cost = float(rw @ rw)
        delta = np.zeros_like(x)
        improved = False
        while lam <= 1e6:
            delta = np.linalg.solve(a + lam * np.diag(np.diag(a) + 1e-9), -g)
            r_new = residuals(x + delta)
            if float(((r_new * _huber(r_new)) ** 2).sum()) < cost:
                x = x + delta
                lam = max(lam / 3, 1e-6)
                improved = True
                break
            lam *= 4
        if not improved or np.abs(delta).max() < 1e-3:
            break
    params, fov = unpack(x)
    return [Pose(float(a), float(b), float(c)) for a, b, c in params], fov


# --- projection ----------------------------------------------------------------------------------

def _directions(width: int, height: int) -> np.ndarray:
    lon = (np.arange(width) + 0.5) / width * 2 * np.pi - np.pi
    lat = np.pi / 2 - (np.arange(height) + 0.5) / height * np.pi
    lon, lat = np.meshgrid(lon, lat)
    return np.stack([np.cos(lat) * np.sin(lon), np.sin(lat), np.cos(lat) * np.cos(lon)], axis=-1)


def _gains(warped: list) -> list[float]:
    """Per-frame brightness gains that even out exposure where frames overlap (least squares,
    pulled towards 1 so the sphere keeps the camera's exposure)."""
    n = len(warped)
    step = 4
    lum = []
    for item in warped:
        if item is None:
            lum.append(None)
            continue
        (r0, c0), image, inside, _ = item
        small = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)[::step, ::step].astype(np.float32)
        lum.append((r0, c0, small, inside[::step, ::step]))
    rows, rhs = [], []
    for i in range(n):
        for j in range(i + 1, n):
            if lum[i] is None or lum[j] is None:
                continue
            ri, ci, li, mi = lum[i]
            rj, cj, lj, mj = lum[j]
            r0, c0 = max(ri, rj), max(ci, cj)
            r1 = min(ri + li.shape[0] * step, rj + lj.shape[0] * step)
            c1 = min(ci + li.shape[1] * step, cj + lj.shape[1] * step)
            if r1 - r0 < step * 8 or c1 - c0 < step * 8:
                continue
            hh, ww = (r1 - r0) // step, (c1 - c0) // step
            ai, aj = (r0 - ri) // step, (c0 - ci) // step
            bi, bj = (r0 - rj) // step, (c0 - cj) // step
            a, b = li[ai:ai + hh, aj:aj + ww], lj[bi:bi + hh, bj:bj + ww]
            m = mi[ai:ai + hh, aj:aj + ww] & mj[bi:bi + hh, bj:bj + ww]
            if a.shape != b.shape or m.sum() < 200:
                continue
            weight = math.sqrt(int(m.sum())) / 10
            row = np.zeros(n)
            row[i], row[j] = float(a[m].mean()) * weight, -float(b[m].mean()) * weight
            rows.append(row)
            rhs.append(0.0)
    if not rows:
        return [1.0] * n
    for i in range(n):
        row = np.zeros(n)
        row[i] = 40.0  # stay near the camera's exposure
        rows.append(row)
        rhs.append(40.0)
    gains, *_ = np.linalg.lstsq(np.array(rows), np.array(rhs), rcond=None)
    return [float(np.clip(g, 0.6, 1.6)) for g in gains]


def stitch(frames: list[np.ndarray], poses: list[Pose], long_side_fov: float = DEFAULT_LONG_SIDE_FOV,
           width: int = EQUIRECT_WIDTH, refine_poses: bool = True) -> PhotoSphere:
    if len(frames) < 2 or len(frames) != len(poses):
        raise ValueError("A photo sphere needs at least two frames, each with its orientation")
    frames = [_resize(f, FRAME_SIDE) for f in frames]
    notes: list[str] = []
    fov_measured = yaw_corrected = False
    if refine_poses:
        small = [_resize(f, 800) for f in frames]
        # First the eye-level ring (field of view, drift closed around the turn), then every
        # overlapping pair together.
        fov, poses, fov_measured, yaw_corrected = refine(small, poses, long_side_fov)
        poses, fov, pairs = bundle_adjust(small, poses, fov, fit_fov=True)
        if pairs >= 3:
            fov_measured = yaw_corrected = True
        long_side_fov = fov
    if not fov_measured:
        notes.append("Field of view assumed, not measured (too little overlap between photos).")
    origin = poses[0].yaw
    poses = [Pose(p.yaw - origin, p.pitch, p.roll) for p in poses]

    height = width // 2
    dirs = _directions(width, height).astype(np.float32)
    # Each frame warped onto the sphere, with how centrally it sees each pixel.
    warped: list = []
    best = np.zeros((height, width), np.float32)
    label = np.full((height, width), -1, np.int16)
    for index, (frame, pose) in enumerate(zip(frames, poses)):
        h, w = frame.shape[:2]
        f = focal(w, h, long_side_fov)
        cam = dirs @ rotation(pose).astype(np.float32)          # world -> camera (R is orthonormal)
        z = cam[..., 2]
        visible = z > 0.05
        with np.errstate(divide="ignore", invalid="ignore"):
            u = np.where(visible, w / 2 + f * cam[..., 0] / z, -1).astype(np.float32)
            v = np.where(visible, h / 2 - f * cam[..., 1] / z, -1).astype(np.float32)
        inside = visible & (u >= 1) & (u < w - 2) & (v >= 1) & (v < h - 2)
        if not inside.any():
            warped.append(None)
            continue
        rows, cols = np.where(inside.any(axis=1))[0], np.where(inside.any(axis=0))[0]
        r0, r1, c0, c1 = int(rows[0]), int(rows[-1]) + 1, int(cols[0]), int(cols[-1]) + 1
        sub = (slice(r0, r1), slice(c0, c1))
        image = cv2.remap(frame, u[sub], v[sub], cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
        wx = np.clip(np.minimum(u[sub], w - 1 - u[sub]) / (w / 2), 0, 1)
        wy = np.clip(np.minimum(v[sub], h - 1 - v[sub]) / (h / 2), 0, 1)
        centrality = np.where(inside[sub], wx * wy, 0).astype(np.float32)
        region_best, region_label = best[sub], label[sub]
        better = centrality > region_best
        region_best[better] = centrality[better]
        region_label[better] = index
        warped.append(((r0, c0), image, inside[sub], centrality))
    covered = label >= 0

    # Exposure: even out brightness between frames before blending.
    gains = _gains(warped)

    # Seams: where two frames overlap, the cut runs where they already agree (a graph cut on
    # colour and edges, as panorama stitchers do), so it avoids people, desks and shelf edges
    # that differ between frames. Without it, each pixel comes from the frame that sees it
    # most centrally. Either way no pixel is an average of two frames, so nothing is doubled.
    seams = _graph_cut_seams(warped, gains, width)
    blender = cv2.detail_MultiBandBlender(0, 5)
    blender.prepare((0, 0, width, height))
    kernel = np.ones((21, 21), np.uint8)
    for index, item in enumerate(warped):
        if item is None:
            continue
        (r0, c0), image, inside, _ = item
        inside_mask = inside.astype(np.uint8) * 255
        if seams is not None and seams[index] is not None:
            own = seams[index] & inside_mask
        else:
            own = (label[r0:r0 + image.shape[0], c0:c0 + image.shape[1]] == index).astype(np.uint8) * 255
        if not own.any():
            continue
        # Each frame reaches a little past its seam so the bands have something to blend.
        mask = cv2.dilate(own, kernel) & inside_mask
        adjusted = np.clip(image.astype(np.float32) * gains[index], 0, 255).astype(np.int16)
        blender.feed(adjusted, mask, (c0, r0))
    blended, _ = blender.blend(None, None)
    image = np.clip(blended, 0, 255).astype(np.float32)

    # Areas no photo covered (usually the ceiling and floor) get a soft blur of their
    # surroundings, as Street View does, rather than black.
    if not covered.all():
        small_w, small_h = 256, 128
        acc = cv2.resize(image * covered[..., None], (small_w, small_h), interpolation=cv2.INTER_AREA)
        cov = cv2.resize(covered.astype(np.float32), (small_w, small_h), interpolation=cv2.INTER_AREA)
        for _ in range(6):
            acc = cv2.GaussianBlur(acc, (0, 0), 6, borderType=cv2.BORDER_REFLECT)
            cov = cv2.GaussianBlur(cov, (0, 0), 6, borderType=cv2.BORDER_REFLECT)
        fill = acc / np.maximum(cov, 1e-4)[..., None]
        fill[cov < 1e-4] = (60, 60, 60)
        fill = cv2.resize(fill, (width, height), interpolation=cv2.INTER_LINEAR)
        image[~covered] = fill[~covered]
    image = np.clip(image, 0, 255).astype(np.uint8)
    return PhotoSphere(image, len(frames), long_side_fov, fov_measured, yaw_corrected, float(covered.mean()), notes)


def _graph_cut_seams(warped: list, gains: list[float], width: int, work_width: int = 1024) -> list | None:
    """Per-frame masks (full size, 0/255) after a graph-cut seam search at reduced size."""
    scale = work_width / width
    images, corners, masks, index_of = [], [], [], []
    for index, item in enumerate(warped):
        if item is None:
            continue
        (r0, c0), image, inside, _ = item
        h, w = image.shape[:2]
        size = (max(2, round(w * scale)), max(2, round(h * scale)))
        small = cv2.resize(image, size, interpolation=cv2.INTER_AREA).astype(np.float32) * gains[index]
        mask = cv2.resize(inside.astype(np.uint8) * 255, size, interpolation=cv2.INTER_NEAREST)
        images.append(cv2.UMat(small))
        corners.append((round(c0 * scale), round(r0 * scale)))
        masks.append(cv2.UMat(mask))
        index_of.append(index)
    if len(images) < 2:
        return None
    try:
        found = cv2.detail_GraphCutSeamFinder("COST_COLOR_GRAD").find(images, corners, masks)
    except cv2.error:
        return None
    result: list = [None] * len(warped)
    for index, mask in zip(index_of, found):
        (_, _), image, _, _ = warped[index]
        h, w = image.shape[:2]
        big = cv2.resize(mask.get(), (w, h), interpolation=cv2.INTER_LINEAR)
        result[index] = np.where(big > 127, 255, 0).astype(np.uint8)
    return result


def with_photosphere_xmp(jpeg: bytes, width: int, height: int) -> bytes:
    """Adds Google's GPano metadata so photo apps open the image as a 360° sphere."""
    xmp = (
        '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
        '<rdf:Description rdf:about="" xmlns:GPano="http://ns.google.com/photos/1.0/panorama/" '
        'GPano:ProjectionType="equirectangular" GPano:UsePanoramaViewer="True" '
        f'GPano:FullPanoWidthPixels="{width}" GPano:FullPanoHeightPixels="{height}" '
        f'GPano:CroppedAreaImageWidthPixels="{width}" GPano:CroppedAreaImageHeightPixels="{height}" '
        'GPano:CroppedAreaLeftPixels="0" GPano:CroppedAreaTopPixels="0"/></rdf:RDF></x:xmpmeta>'
    ).encode()
    payload = b"http://ns.adobe.com/xap/1.0/\x00" + xmp
    segment = b"\xff\xe1" + (len(payload) + 2).to_bytes(2, "big") + payload
    return jpeg[:2] + segment + jpeg[2:]


# --- recognition on flat views -------------------------------------------------------------------

def render_view(equirect: np.ndarray, yaw: float, fov: float = VIEW_FOV, side: int = VIEW_SIDE) -> np.ndarray:
    """A flat camera view [fov]° wide looking at heading [yaw] on the horizon."""
    height, width = equirect.shape[:2]
    f = side / 2 / math.tan(math.radians(fov) / 2)
    xs = (np.arange(side) + 0.5 - side / 2) / f
    ys = -(np.arange(side) + 0.5 - side / 2) / f
    x, y = np.meshgrid(xs, ys)
    rays = np.stack([x, y, np.ones_like(x)], axis=-1) @ rotation(Pose(yaw, 0, 0)).T
    lon = np.arctan2(rays[..., 0], rays[..., 2])
    lat = np.arctan2(rays[..., 1], np.hypot(rays[..., 0], rays[..., 2]))
    mx = ((lon + np.pi) / (2 * np.pi) * width - 0.5).astype(np.float32)
    my = ((np.pi / 2 - lat) / np.pi * height - 0.5).astype(np.float32)
    return cv2.remap(equirect, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_WRAP)


def view_box_to_equirect(box: tuple[float, float, float, float], yaw: float, fov: float = VIEW_FOV) -> tuple[float, float, float, float, float]:
    """Normalised box in a view -> (x, y, width, height) on the equirectangular image, plus the
    centre's heading relative to the view (degrees)."""
    x, y, w, h = box
    t = math.tan(math.radians(fov) / 2)
    samples = [(x + w * i / 4, y + h * j / 4) for i in range(5) for j in range(5)]
    lons, lats = [], []
    for sx, sy in samples:
        ray = np.array([(2 * sx - 1) * t, (1 - 2 * sy) * t, 1.0]) @ rotation(Pose(yaw, 0, 0)).T
        lons.append(math.degrees(math.atan2(ray[0], ray[2])))
        lats.append(math.degrees(math.atan2(ray[1], math.hypot(ray[0], ray[2]))))
    # Unwrap around the box's own heading so a box across the ±180° seam stays whole.
    ref = lons[12]
    lons = [ref + ((v - ref + 180) % 360 - 180) for v in lons]
    left, right = min(lons), max(lons)
    top, bottom = max(lats), min(lats)
    ex = ((left + 180) / 360) % 1.0
    relative = math.degrees(math.atan((2 * (x + w / 2) - 1) * t))
    return ex, (90 - top) / 180, (right - left) / 360, (top - bottom) / 180, relative


def analyze(provider, equirect_jpeg: bytes, catalog, own_manufacturer_id):  # type: ignore[no-untyped-def]
    """Runs [provider] on flat views around the horizon and maps the boxes onto the sphere.
    A pack seen in two neighbouring views is kept from the view it is most central in."""
    from .base import ProviderDetection, ProviderResult
    from .imaging import decode_upright

    equirect = decode_upright(equirect_jpeg)
    if equirect is None:
        raise ValueError("Photo sphere image is unreadable")
    step = 360 / len(VIEW_YAWS)
    detections: list[ProviderDetection] = []
    warnings: list[str] = []
    cost = 0.0
    for yaw in VIEW_YAWS:
        view = render_view(equirect, yaw)
        ok, encoded = cv2.imencode(".jpg", view, [int(cv2.IMWRITE_JPEG_QUALITY), 92])
        if not ok:
            continue
        result = provider.analyze(encoded.tobytes(), catalog, own_manufacturer_id)
        cost += result.cost_usd or 0.0
        warnings.extend(w for w in result.warnings if w not in warnings)
        for d in result.detections:
            ex, ey, ew, eh, relative = view_box_to_equirect((d.x, d.y, d.width, d.height), yaw)
            if abs(relative) > step / 2:
                continue  # its neighbouring view sees it more centrally
            detections.append(ProviderDetection(
                x=ex, y=ey, width=ew, height=eh, label=d.label, confidence=d.confidence,
                product_id=d.product_id, manufacturer_id=d.manufacturer_id,
                evidence={**d.evidence, "sphere_view": yaw},
            ))
    return ProviderResult(detections=detections, warnings=warnings, cost_usd=cost or None,
                          raw={"views": list(VIEW_YAWS), "view_fov": VIEW_FOV})
