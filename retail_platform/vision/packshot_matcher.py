"""Pack-shot lookup: finds catalogue products in a shelf photo by matching local image
features against the catalogue's pack shots. No training, no external service.

How it works:
  * index — every pack shot is cut out from its background (transparency or the white
    studio backdrop), split when one image shows several separate packs, and described
    with SIFT keypoints; all descriptors go into one FLANN index;
  * match — the photo's SIFT descriptors are matched to the index (Lowe ratio test) and
    grouped by pack shot; a pack shot with enough matches is verified geometrically with
    a RANSAC homography, which also gives the pack's outline on the shelf. Inlier matches
    are removed and the search repeats, so several facings of the same product are found;
  * confidence grows with the number of geometrically consistent matches and their share.

What it is good at: flat printed packaging (pouches, cartons, boxes) seen from the front
at arm's length. What it misses: strongly curved jars and bottles, glare, packs that are
small in the frame, and artwork that differs from the pack shot. Products without a pack
shot are never found, so "not boxed" does not prove "not ours". It is a demonstration
recogniser; accuracy has to be measured on real photos before decisions rest on it.
"""

from __future__ import annotations

import hashlib
import logging
import math
import threading
import time
from dataclasses import dataclass, field

import cv2
import numpy as np

from .base import CatalogEntry, ProviderDetection, ProviderResult, VisionProvider

log = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class MatcherConfig:
    reference_side: int = 640       # pack shots are described at this size
    frame_side: int = 1100          # photos (or panorama tiles) are matched at this size
    reference_features: int = 1500
    frame_features: int = 5000
    ratio: float = 0.75             # Lowe ratio test
    min_matches: int = 10           # matches a pack shot needs before geometry is checked
    min_inliers: int = 9            # geometrically consistent matches to accept a facing
    max_instances: int = 8          # facings of one pack shot searched per photo
    ransac_px: float = 5.0
    min_area: float = 0.0015        # of the frame; smaller outlines are noise
    max_area: float = 0.9


@dataclass(slots=True)
class Match:
    product_id: str
    inliers: int
    matches: int
    confidence: float
    box: tuple[float, float, float, float]          # normalised x, y, width, height
    polygon: list[tuple[float, float]] = field(default_factory=list)


@dataclass(slots=True)
class _Reference:
    product_id: str
    points: np.ndarray        # keypoint coordinates, N x 2
    width: int
    height: int


def _decode(data: bytes) -> np.ndarray | None:
    return cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_UNCHANGED)


def _foreground(image: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """BGR pack shot plus a mask of the pack: alpha channel, or everything that is not studio white."""
    if image.ndim == 2:
        image = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)
    if image.shape[2] == 4:
        alpha = image[:, :, 3]
        bgr = image[:, :, :3].astype(np.float32)
        a = (alpha.astype(np.float32) / 255.0)[:, :, None]
        bgr = (bgr * a + 255 * (1 - a)).astype(np.uint8)
        mask = (alpha > 40).astype(np.uint8) * 255
    else:
        bgr = image[:, :, :3]
        mask = (bgr.min(axis=2) < 235).astype(np.uint8) * 255
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8))
    return bgr, mask


def split_packs(data: bytes) -> list[np.ndarray]:
    """Crops of the separate packs in a pack shot (one crop when the packs touch or there is one)."""
    image = _decode(data)
    if image is None:
        return []
    bgr, mask = _foreground(image)
    count, _, stats, _ = cv2.connectedComponentsWithStats(mask)
    boxes = [stats[i, :4] for i in range(1, count)]
    if not boxes:
        return [bgr]
    largest = max(b[2] * b[3] for b in boxes)
    keep = [b for b in boxes if b[2] * b[3] >= 0.15 * largest]
    if len(keep) == 1:
        x, y, w, h = keep[0]
        return [bgr[y:y + h, x:x + w]]
    return [bgr[y:y + h, x:x + w] for x, y, w, h in keep]


def _resize(image: np.ndarray, side: int) -> tuple[np.ndarray, float]:
    scale = side / max(image.shape[:2])
    if scale >= 1:
        return image, 1.0
    return cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA), scale


class PackshotIndex:
    """SIFT descriptors of every pack shot, searchable together."""

    def __init__(self, references: list[tuple[str, bytes]], config: MatcherConfig | None = None) -> None:
        self.config = config or MatcherConfig()
        started = time.perf_counter()
        sift = cv2.SIFT_create(nfeatures=self.config.reference_features)
        self.references: list[_Reference] = []
        descriptors: list[np.ndarray] = []
        owners: list[np.ndarray] = []
        for product_id, data in references:
            for crop in split_packs(data):
                crop, _ = _resize(crop, self.config.reference_side)
                keypoints, desc = sift.detectAndCompute(cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY), None)
                if desc is None or len(keypoints) < self.config.min_matches:
                    continue
                owners.append(np.full(len(keypoints), len(self.references), dtype=np.int32))
                descriptors.append(desc)
                self.references.append(_Reference(product_id, np.float32([k.pt for k in keypoints]),
                                                  crop.shape[1], crop.shape[0]))
        self.products = sorted({r.product_id for r in self.references})
        self._owner = np.concatenate(owners) if owners else np.zeros(0, np.int32)
        self._points = np.concatenate([r.points for r in self.references]) if self.references else np.zeros((0, 2), np.float32)
        self._matcher = None
        if descriptors:
            self._matcher = cv2.FlannBasedMatcher({"algorithm": 1, "trees": 5}, {"checks": 64})
            self._matcher.add([np.concatenate(descriptors)])
            self._matcher.train()
        self._lock = threading.Lock()  # FLANN matchers are not safe to share between threads
        self.build_seconds = round(time.perf_counter() - started, 2)
        log.info("pack-shot index: %d products, %d views, %d descriptors in %.1fs",
                 len(self.products), len(self.references), len(self._owner), self.build_seconds)

    def __len__(self) -> int:
        return len(self.references)

    def match(self, image: np.ndarray) -> list[Match]:
        """All facings found in a BGR image. Wide images (panoramas) are searched in overlapping tiles."""
        if self._matcher is None:
            return []
        height, width = image.shape[:2]
        if width <= 1.8 * height:
            return self._match_tile(image, 0, 0, width, height)
        tile, step = int(1.3 * height), int(0.9 * height)
        found: list[Match] = []
        for x0 in range(0, max(1, width - tile + step), step):
            x1 = min(width, x0 + tile)
            found += self._match_tile(image[:, x0:x1], x0, 0, width, height)
            if x1 == width:
                break
        return _suppress(found)

    def _match_tile(self, tile: np.ndarray, offset_x: int, offset_y: int, full_w: int, full_h: int) -> list[Match]:
        cfg = self.config
        small, scale = _resize(tile, cfg.frame_side)
        sift = cv2.SIFT_create(nfeatures=cfg.frame_features)
        keypoints, desc = sift.detectAndCompute(cv2.cvtColor(small, cv2.COLOR_BGR2GRAY), None)
        if desc is None or len(keypoints) < cfg.min_matches:
            return []
        with self._lock:
            pairs = self._matcher.knnMatch(desc, k=2)
        frame_points = np.float32([k.pt for k in keypoints]) / scale
        frame_points[:, 0] += offset_x
        frame_points[:, 1] += offset_y
        by_reference: dict[int, list[tuple[int, int]]] = {}
        for pair in pairs:
            if len(pair) < 2 or pair[0].distance >= cfg.ratio * pair[1].distance:
                continue
            best = pair[0]
            by_reference.setdefault(int(self._owner[best.trainIdx]), []).append((best.queryIdx, best.trainIdx))
        area_full = full_w * full_h
        found: list[Match] = []
        for ref_index, pairs_for_ref in by_reference.items():
            reference = self.references[ref_index]
            remaining = pairs_for_ref
            for _ in range(cfg.max_instances):
                if len(remaining) < cfg.min_matches:
                    break
                src = np.float32([self._points[t] for _, t in remaining])
                dst = np.float32([frame_points[q] for q, _ in remaining])
                homography, mask = cv2.findHomography(src, dst, cv2.RANSAC, cfg.ransac_px / scale)
                if homography is None:
                    break
                inliers = int(mask.sum())
                if inliers < cfg.min_inliers:
                    break
                corners = np.float32([[0, 0], [reference.width, 0], [reference.width, reference.height],
                                      [0, reference.height]]).reshape(-1, 1, 2)
                outline = cv2.perspectiveTransform(corners, homography).reshape(-1, 2)
                keep = [p for p, m in zip(remaining, mask.ravel()) if not m]
                if _plausible(outline, area_full, cfg):
                    x0, y0 = outline.min(axis=0)
                    x1, y1 = outline.max(axis=0)
                    x0, y0 = max(0.0, x0), max(0.0, y0)
                    x1, y1 = min(float(full_w), x1), min(float(full_h), y1)
                    ratio = inliers / len(remaining)
                    found.append(Match(
                        product_id=reference.product_id, inliers=inliers, matches=len(remaining),
                        confidence=_confidence(inliers, ratio),
                        box=(float(x0 / full_w), float(y0 / full_h), float((x1 - x0) / full_w),
                             float((y1 - y0) / full_h)),
                        polygon=[(float(px) / full_w, float(py) / full_h) for px, py in outline],
                    ))
                remaining = keep
        return _suppress(found)


def _plausible(outline: np.ndarray, frame_area: float, cfg: MatcherConfig) -> bool:
    """Rejects degenerate homographies: twisted, mirrored, tiny or frame-filling outlines."""
    contour = outline.reshape(-1, 1, 2).astype(np.float32)
    if not cv2.isContourConvex(contour):
        return False
    area = cv2.contourArea(contour)
    if not cfg.min_area * frame_area <= area <= cfg.max_area * frame_area:
        return False
    sides = [np.linalg.norm(outline[i] - outline[(i + 1) % 4]) for i in range(4)]
    # Opposite sides of a pack seen roughly from the front stay within a factor of 2.5.
    return max(sides[0], sides[2]) <= 2.5 * min(sides[0], sides[2]) and \
        max(sides[1], sides[3]) <= 2.5 * min(sides[1], sides[3])


def _confidence(inliers: int, ratio: float) -> float:
    """Heuristic, not calibrated: ~0.5 at 15 consistent matches, ~0.9 at 30, scaled by their share."""
    strength = 1 / (1 + math.exp(-(inliers - 15) / 5))
    return round(min(0.99, strength * (0.7 + 0.3 * ratio)), 3)


def _iou(a: tuple[float, float, float, float], b: tuple[float, float, float, float]) -> float:
    ax1, ay1, bx1, by1 = a[0] + a[2], a[1] + a[3], b[0] + b[2], b[1] + b[3]
    iw = max(0.0, min(ax1, bx1) - max(a[0], b[0]))
    ih = max(0.0, min(ay1, by1) - max(a[1], b[1]))
    inter = iw * ih
    union = a[2] * a[3] + b[2] * b[3] - inter
    return inter / union if union else 0.0


def _suppress(matches: list[Match], threshold: float = 0.4) -> list[Match]:
    """One facing per place: keep the strongest of overlapping outlines (any product)."""
    kept: list[Match] = []
    for match in sorted(matches, key=lambda m: -m.inliers):
        if all(_iou(match.box, other.box) < threshold for other in kept):
            kept.append(match)
    return kept


# --- provider -----------------------------------------------------------------------------------

_COLOURS = {"own": (94, 197, 34), "competitor": (60, 60, 220), "unknown": (150, 150, 150)}  # BGR


class PackshotMatchProvider:
    """Vision provider over the pack-shot index. Facings of products it cannot look up can come
    from a fallback detector (the OpenCV baseline): those are kept as unidentified boxes, so
    the shelf still shows that something other than a catalogued product is there."""

    provider = "packshot-match"
    model_code = "packshot-lookup"
    # What the pipeline should attach to catalogue entries: every pack shot, at matching size.
    reference_side = 640
    reference_limit: int | None = None
    references_per_product = 6

    def __init__(self, fallback: VisionProvider | None = None, config: MatcherConfig | None = None) -> None:
        self.fallback = fallback
        self.matcher_config = config or MatcherConfig()
        cfg = self.matcher_config
        self.reference_side = cfg.reference_side
        digest = hashlib.sha256(repr(cfg).encode()).hexdigest()[:10]
        self.version = f"sift-flann-homography@{digest}"
        self.config = {"matcher": {k: getattr(cfg, k) for k in cfg.__dataclass_fields__},
                       "fallback": fallback.provider if fallback else None}
        self._indexes: dict[str, PackshotIndex] = {}
        self._lock = threading.Lock()

    def index_for(self, catalog: list[CatalogEntry]) -> PackshotIndex:
        references = [(e.product_id, shot) for e in catalog for shot in e.reference_images]
        key = hashlib.blake2b(b"".join(p.encode() + hashlib.blake2b(s, digest_size=8).digest()
                                       for p, s in references), digest_size=16).hexdigest()
        with self._lock:
            index = self._indexes.get(key)
            if index is None:
                if len(self._indexes) > 8:
                    self._indexes.clear()
                index = self._indexes[key] = PackshotIndex(references, self.matcher_config)
        return index

    def find(self, image: bytes | np.ndarray, catalog: list[CatalogEntry]) -> list[Match]:
        array = _decode(image) if isinstance(image, bytes) else image
        if array is None:
            raise ValueError("Unable to decode image")
        if array.ndim == 3 and array.shape[2] == 4:
            array = array[:, :, :3]
        return self.index_for(catalog).match(array)

    def look(self, image: np.ndarray, catalog: list[CatalogEntry]) -> list:  # list[visual_lookup.Look]
        from .visual_lookup import Look

        return [Look(m.box, m.confidence, m.product_id, m.polygon, "exact",
                     {"inliers": m.inliers, "matches": m.matches}) for m in self.find(image, catalog)]

    def analyze(self, image: bytes, catalog: list[CatalogEntry], own_manufacturer_id: str | None) -> ProviderResult:
        array = cv2.imdecode(np.frombuffer(image, dtype=np.uint8), cv2.IMREAD_COLOR)
        if array is None:
            raise ValueError("Unable to decode image")
        by_id = {e.product_id: e for e in catalog}
        index = self.index_for(catalog)
        warnings: list[str] = []
        if not len(index):
            if self.fallback is None:
                raise RuntimeError("No pack shots in the catalogue to look up")
            result = self.fallback.analyze(image, catalog, own_manufacturer_id)
            result.warnings.insert(0, "No pack shots loaded, so products cannot be looked up; "
                                      "showing basic detection. Import pack shots first.")
            return result
        detections = []
        for match in index.match(array):
            entry = by_id[match.product_id]
            detections.append(ProviderDetection(
                *match.box, label="own" if entry.is_own else "competitor", confidence=match.confidence,
                product_id=entry.product_id, manufacturer_id=entry.manufacturer_id,
                evidence={"matcher": {"inliers": match.inliers, "matches": match.matches,
                                      "polygon": [list(p) for p in match.polygon]}},
            ))
        raw: dict = {"looked_up": len(detections), "index_products": len(index.products)}
        if self.fallback is not None:
            # Facings the baseline sees where no pack shot matched: something is there, not identified.
            for other in self.fallback.analyze(image, catalog, own_manufacturer_id).detections:
                box = (other.x, other.y, other.width, other.height)
                if all(_iou(box, (d.x, d.y, d.width, d.height)) < 0.3 for d in detections):
                    detections.append(ProviderDetection(*box, label="unknown", confidence=min(other.confidence, 0.4),
                                                        evidence={"from": self.fallback.provider, **other.evidence}))
            raw["unidentified_from_fallback"] = len(detections) - raw["looked_up"]
        warnings.append(f"Products are looked up against pack shots of {len(index.products)} catalogue products; "
                        "products without a pack shot are never identified.")
        return ProviderResult(detections=detections, warnings=warnings, annotated_jpeg=annotate(array, detections, by_id),
                              raw=raw)


def annotate(image: np.ndarray, detections: list[ProviderDetection], by_id: dict[str, CatalogEntry]) -> bytes | None:
    canvas = image.copy()
    height, width = canvas.shape[:2]
    thickness = max(2, round(max(height, width) / 450))
    font = max(0.45, max(height, width) / 1800)
    for d in detections:
        colour = _COLOURS.get(d.label, _COLOURS["unknown"])
        polygon = (d.evidence.get("matcher") or {}).get("polygon")
        if polygon:
            points = np.int32([[x * width, y * height] for x, y in polygon])
            cv2.polylines(canvas, [points], True, colour, thickness)
        else:
            cv2.rectangle(canvas, (int(d.x * width), int(d.y * height)),
                          (int((d.x + d.width) * width), int((d.y + d.height) * height)), colour, thickness)
        entry = by_id.get(d.product_id or "")
        name = entry.name[:28] if entry else ("Not ours" if d.evidence.get("not_ours") else None)
        if name:
            text = f"{name} {d.confidence:.0%}"
            (_, text_height), _ = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, font, thickness)
            origin = (int(d.x * width) + thickness, int(d.y * height) + text_height + 2 * thickness)  # inside the box
            cv2.putText(canvas, text, origin, cv2.FONT_HERSHEY_SIMPLEX, font, (255, 255, 255), thickness + 2)
            cv2.putText(canvas, text, origin, cv2.FONT_HERSHEY_SIMPLEX, font, colour, thickness)
    ok, encoded = cv2.imencode(".jpg", canvas, [int(cv2.IMWRITE_JPEG_QUALITY), 85])
    return encoded.tobytes() if ok else None
