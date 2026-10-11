"""Visual lookup: finds every pack on the shelf with a pretrained open-vocabulary detector and
names it by visual similarity to the catalogue's pack shots. No training, no external service.

Pack-shot SIFT matching (packshot_matcher) needs the photographed artwork to be identical to the
pack shot. This recogniser tolerates redrawn or re-rendered artwork (AI-generated shelf images,
packaging refreshes), at the price of confusing close variants of one design family:

  * clean  — colours are stretched per channel and moire smoothed (screen_photo). A photo of a
             screen (detected by its outline or its pixel-grid spectrum) is judged with lower
             acceptance thresholds, since moire and washed-out colour lower every score;
  * find   — OWLv2 (google/owlv2-base-patch16-ensemble), prompted with "a product package",
             "a jar", ... proposes one box per pack. Wide panoramas are searched in tiles;
  * name   — each box is embedded with CLIP ViT-B/16 (openai/clip-vit-base-patch16) and compared
             with every pack shot. The best product must look alike (cosine similarity) *and*
             share the colours of its pack shot (hue/saturation histogram), otherwise the pack
             is reported as "not one of ours";
  * read   — before that, CLIP compares the box with "a product package with the brand name
             <brand>" for every brand in the catalogue. Competitor brands usually print their
             name in Latin script, which CLIP reads; a confident read names the competitor
             even without a pack shot (the brand's catalogue product is used);
  * exact  — the SIFT pack-shot matcher runs alongside; where it finds an exact match its
             identity and outline win.

Confidence is a heuristic, not a calibrated probability: how far the similarity and colour
agreement clear their thresholds, times how clearly the best product beats the runner-up.
Measured on the 20 AI-generated shelves in FMCG_Shelf_Test_Set_20 (share of Square packs vs the
share each image was made with): 6.6 points mean error shown directly, 10.7 on simulated phone
photos of those images on a monitor (tests/screen_sim.py). The thresholds were tuned on these
images, so they are a demo setting; measure on a labelled set before relying on them.
"""

from __future__ import annotations

import hashlib
import importlib.util
import logging
import math
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

import cv2
import numpy as np

from .base import CatalogEntry, ProviderDetection, ProviderResult
from .packshot_matcher import Match, PackshotMatchProvider, _iou, annotate, split_packs
from .screen_photo import clean, is_screen_photo

log = logging.getLogger(__name__)

DETECTOR = "google/owlv2-base-patch16-ensemble"
EMBEDDER = "openai/clip-vit-base-patch16"
QUERIES = ("a product package", "a box", "a bottle", "a jar", "a snack packet", "a juice carton", "a pouch")
CLIP_MEAN = np.array([0.48145466, 0.4578275, 0.40821073])
CLIP_STD = np.array([0.26862954, 0.26130258, 0.27577711])


def available() -> bool:
    """PyTorch and transformers are installed, and the recogniser is not switched off."""
    if os.getenv("SHELFSIGHT_VISUAL_LOOKUP", "1") == "0":
        return False
    return all(importlib.util.find_spec(m) is not None for m in ("torch", "transformers"))


@dataclass(frozen=True, slots=True)
class VisualConfig:
    detector_side: int = 960          # OWLv2's input size
    box_threshold: float = 0.15       # detector score to consider a box at all
    other_threshold: float = 0.27     # detector score to report a pack that is not ours
    min_area: float = 0.002           # of the frame
    max_area: float = 0.85
    accept_similarity: float = 0.81   # CLIP cosine similarity to the best pack shot
    accept_colour: float = 0.36       # 1 - Bhattacharyya distance of hue/saturation histograms
    # A photo of a screen scores lower on both (moire, washed-out colour): its own thresholds.
    screen_photos: str = "auto"       # auto (detect) | always | never
    screen_similarity: float = 0.74
    screen_colour: float = 0.24
    exact_confidence: float = 0.5     # SIFT matches at least this confident override the lookup
    other_min_size: float = 0.35      # a pack that is not ours must be this share of a typical named pack
    brand_read: float = 0.9           # probability of a competitor brand name to override the lookup
    brand_name_other: float = 0.75    # ... to name a pack the lookup already found is not ours
    debias: bool = True               # subtract each brand prompt's average score on the pack shots
    # Clean-up for photos of a screen (screen_photo): find + straighten it, fix colours, remove moire.
    screen_rectify: bool = False      # off: on real shelves a bright area can pass for a screen
    colour_normalise: bool = True
    demoire: bool = True


@dataclass(slots=True)
class Look:
    """One pack on the shelf: a catalogue product, or a pack that is not one of ours."""

    box: tuple[float, float, float, float]       # normalised x, y, width, height
    confidence: float
    product_id: str | None = None
    polygon: list[tuple[float, float]] = field(default_factory=list)
    method: str = "visual"                       # visual | exact
    evidence: dict = field(default_factory=dict)


class _Models:
    """OWLv2 and CLIP, loaded once per process and shared (inference is serialised)."""

    _instance: _Models | None = None
    _create_lock = threading.Lock()

    def __init__(self) -> None:
        import torch
        from transformers import AutoTokenizer, CLIPModel, Owlv2ForObjectDetection

        started = time.perf_counter()
        self.torch = torch
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.dtype = torch.float16 if self.device == "cuda" else torch.float32
        self.detector = Owlv2ForObjectDetection.from_pretrained(DETECTOR, dtype=self.dtype).to(self.device).eval()
        tokens = AutoTokenizer.from_pretrained(DETECTOR)(list(QUERIES), padding="max_length", max_length=16,
                                                         return_tensors="pt")
        self.input_ids = tokens.input_ids.to(self.device)
        self.attention_mask = tokens.attention_mask.to(self.device)
        self.embedder = CLIPModel.from_pretrained(EMBEDDER, dtype=self.dtype).to(self.device).eval()
        self.clip_tokenizer = AutoTokenizer.from_pretrained(EMBEDDER)
        self._texts: dict[tuple[str, ...], np.ndarray] = {}
        self.lock = threading.Lock()
        log.info("visual lookup models on %s in %.1fs", self.device, time.perf_counter() - started)

    @classmethod
    def get(cls) -> _Models:
        with cls._create_lock:
            if cls._instance is None:
                cls._instance = cls()
            return cls._instance

    def _tensor(self, batch: np.ndarray):  # type: ignore[no-untyped-def]
        return self.torch.from_numpy(batch).to(self.device, self.dtype)

    def detect(self, bgr: np.ndarray, side: int) -> tuple[np.ndarray, np.ndarray]:
        """Boxes (x0, y0, x1, y1 in pixels) and scores for one image, padded to a square."""
        height, width = bgr.shape[:2]
        square = max(height, width)
        canvas = np.full((square, square, 3), 128, np.uint8)
        canvas[:height, :width] = bgr
        rgb = cv2.resize(cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB), (side, side), interpolation=cv2.INTER_AREA)
        batch = (((rgb / 255.0) - CLIP_MEAN) / CLIP_STD).transpose(2, 0, 1)[None].astype(np.float32)
        with self.lock, self.torch.no_grad():
            out = self.detector(input_ids=self.input_ids, attention_mask=self.attention_mask,
                                pixel_values=self._tensor(batch))
            scores = out.logits[0].float().sigmoid().max(-1).values.cpu().numpy()
            boxes = out.pred_boxes[0].float().cpu().numpy()
        cx, cy, bw, bh = boxes.T * square
        xyxy = np.stack([cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2], axis=1)
        xyxy[:, 0::2] = xyxy[:, 0::2].clip(0, width)
        xyxy[:, 1::2] = xyxy[:, 1::2].clip(0, height)
        return xyxy, scores

    def text(self, prompts: tuple[str, ...]) -> np.ndarray:
        """L2-normalised CLIP text embeddings, cached per prompt set."""
        cached = self._texts.get(prompts)
        if cached is None:
            tokens = self.clip_tokenizer(list(prompts), padding=True, return_tensors="pt").to(self.device)
            with self.lock, self.torch.no_grad():
                features = self.embedder.get_text_features(**tokens).float()
            cached = self._texts[prompts] = self.torch.nn.functional.normalize(features, dim=-1).cpu().numpy()
        return cached

    def embed(self, crops: list[np.ndarray]) -> np.ndarray:
        """L2-normalised CLIP image embeddings, one row per crop."""
        if not crops:
            return np.zeros((0, 512), np.float32)
        rows = []
        for start in range(0, len(crops), 64):
            batch = np.stack([_clip_input(c) for c in crops[start:start + 64]])
            with self.lock, self.torch.no_grad():
                features = self.embedder.get_image_features(pixel_values=self._tensor(batch)).float()
            rows.append(self.torch.nn.functional.normalize(features, dim=-1).cpu().numpy())
        return np.concatenate(rows)


def _clip_input(crop: np.ndarray) -> np.ndarray:
    """Pad to a white square (pack shots are on white) and resize to CLIP's 224 px."""
    height, width = crop.shape[:2]
    side = max(height, width)
    square = np.full((side, side, 3), 255, np.uint8)
    top, left = (side - height) // 2, (side - width) // 2
    square[top:top + height, left:left + width] = crop
    rgb = cv2.resize(cv2.cvtColor(square, cv2.COLOR_BGR2RGB), (224, 224), interpolation=cv2.INTER_AREA)
    return (((rgb / 255.0) - CLIP_MEAN) / CLIP_STD).transpose(2, 0, 1).astype(np.float32)


def _colours(image: np.ndarray) -> np.ndarray:
    """Hue/saturation histogram of the coloured (non-white) part of an image."""
    hsv = cv2.cvtColor(cv2.resize(image, (128, 128), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2HSV)
    mask = ((hsv[:, :, 2] < 245) | (hsv[:, :, 1] > 20)).astype(np.uint8)
    hist = cv2.calcHist([hsv], [0, 1], mask, [18, 8], [0, 180, 0, 256])
    return cv2.normalize(hist, hist, 1, 0, cv2.NORM_L1)


def _bounds(polygon: list[tuple[float, float]]) -> tuple[float, float, float, float]:
    xs, ys = [p[0] for p in polygon], [p[1] for p in polygon]
    return min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)


def _covered(a: tuple[float, float, float, float], b: tuple[float, float, float, float]) -> float:
    """Share of box a that lies inside box b."""
    iw = max(0.0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
    ih = max(0.0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
    return iw * ih / (a[2] * a[3]) if a[2] * a[3] else 0.0


def _brands(catalog: list[CatalogEntry]) -> list[CatalogEntry]:
    """One catalogue entry per brand: for competitors, preferably the brand's placeholder product
    (one without pack shots); our own brands are included so their packs are not misread."""
    chosen: dict[str, CatalogEntry] = {}
    for entry in catalog:
        if not entry.brand or entry.brand.lower().startswith("square food"):
            continue
        current = chosen.get(entry.brand)
        if current is None or (current.reference_images and not entry.reference_images):
            chosen[entry.brand] = entry
    return sorted(chosen.values(), key=lambda e: e.brand)


def _read_brands(models: _Models, embeddings: np.ndarray, brands: list[CatalogEntry], packshots: np.ndarray,
                 debias: bool = True) -> list[tuple[CatalogEntry | None, float]]:
    """For each crop, the brand whose printed name CLIP reads best, and its probability among all
    brands plus a neutral "Bengali writing" prompt (own brands print their names in Bangla).

    Some names score well on any pack ("Moyna Bite" on every snack bag); each prompt's average
    score on the catalogue's pack shots is subtracted, so only a name that stands out counts."""
    prompts = tuple(f'a product package with the brand name "{b.brand}"' for b in brands) +         ("a product package with Bengali writing",)
    text = models.text(prompts)
    logits = 100.0 * embeddings @ text.T
    if debias and len(packshots):
        logits = logits - (100.0 * packshots @ text.T).mean(axis=0, keepdims=True)
    probabilities = np.exp(logits - logits.max(axis=1, keepdims=True))
    probabilities /= probabilities.sum(axis=1, keepdims=True)
    reads: list[tuple[CatalogEntry | None, float]] = []
    for row in probabilities:
        best = int(row.argmax())
        reads.append((brands[best], float(row[best])) if best < len(brands) else (None, float(row[best])))
    return reads


def _sigmoid(x: float) -> float:
    return 1 / (1 + math.exp(-x))


class VisualIndex:
    """CLIP embeddings and colour histograms of every pack shot."""

    def __init__(self, references: list[tuple[str, bytes]], models: _Models) -> None:
        started = time.perf_counter()
        crops: list[np.ndarray] = []
        owners: list[str] = []
        for product_id, data in references:
            for crop in split_packs(data):
                if min(crop.shape[:2]) >= 16:
                    crops.append(crop)
                    owners.append(product_id)
        self.owners = owners
        self.products = sorted(set(owners))
        self.embeddings = models.embed(crops)
        self.colours = [_colours(c) for c in crops]
        self.build_seconds = round(time.perf_counter() - started, 2)
        log.info("visual index: %d products, %d views in %.1fs", len(self.products), len(crops), self.build_seconds)

    def __len__(self) -> int:
        return len(self.owners)


class VisualLookupProvider:
    """Vision provider: detector + CLIP lookup, with the SIFT matcher for exact matches."""

    provider = "visual-lookup"
    model_code = "visual-lookup"
    reference_side = 640
    reference_limit: int | None = None
    references_per_product = 6

    def __init__(self, exact: PackshotMatchProvider | None = None, config: VisualConfig | None = None) -> None:
        self.exact = exact if exact is not None else PackshotMatchProvider(None)
        self.visual_config = config or VisualConfig()
        cfg = self.visual_config
        digest = hashlib.sha256(repr(cfg).encode()).hexdigest()[:10]
        self.version = f"owlv2-b16+clip-b16@{digest}"
        self.config = {"detector": DETECTOR, "embedder": EMBEDDER, "queries": list(QUERIES),
                       "lookup": {k: getattr(cfg, k) for k in cfg.__dataclass_fields__},
                       "exact": self.exact.version}
        self._indexes: dict[str, VisualIndex] = {}
        self._lock = threading.Lock()
        self._pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="exact-match")

    # -- index ---------------------------------------------------------------------------------

    def index_for(self, catalog: list[CatalogEntry]) -> VisualIndex:
        references = [(e.product_id, shot) for e in catalog for shot in e.reference_images]
        key = hashlib.blake2b(b"".join(p.encode() + hashlib.blake2b(s, digest_size=8).digest()
                                       for p, s in references), digest_size=16).hexdigest()
        with self._lock:
            index = self._indexes.get(key)
        if index is None:
            index = VisualIndex(references, _Models.get())
            with self._lock:
                if len(self._indexes) > 8:
                    self._indexes.clear()
                self._indexes[key] = index
        self.exact.index_for(catalog)  # build the SIFT index alongside
        return index

    # -- lookup --------------------------------------------------------------------------------

    def _boxes(self, image: np.ndarray, models: _Models) -> list[tuple[np.ndarray, float]]:
        """Pack boxes in pixels, one per pack: tiles for panoramas, then overlap suppression."""
        cfg = self.visual_config
        height, width = image.shape[:2]
        boxes: list[np.ndarray] = []
        scores: list[np.ndarray] = []
        if width <= 1.8 * height:
            tiles = [(0, image)]
        else:
            tile, step = int(1.3 * height), int(0.9 * height)
            tiles = []
            for x0 in range(0, max(1, width - tile + step), step):
                tiles.append((x0, image[:, x0:min(width, x0 + tile)]))
                if x0 + tile >= width:
                    break
        for x0, tile_image in tiles:
            xyxy, score = models.detect(tile_image, cfg.detector_side)
            keep = score > cfg.box_threshold
            xyxy = xyxy[keep]
            xyxy[:, 0::2] += x0
            boxes.append(xyxy)
            scores.append(score[keep])
        all_boxes = np.concatenate(boxes) if boxes else np.zeros((0, 4))
        all_scores = np.concatenate(scores) if scores else np.zeros(0)
        frame = float(width * height)
        kept: list[tuple[np.ndarray, float]] = []
        for i in np.argsort(-all_scores):
            x0, y0, x1, y1 = all_boxes[i]
            area = (x1 - x0) * (y1 - y0)
            if not cfg.min_area * frame <= area <= cfg.max_area * frame:
                continue
            clear = True
            for other, _ in kept:
                iw = max(0.0, min(x1, other[2]) - max(x0, other[0]))
                ih = max(0.0, min(y1, other[3]) - max(y0, other[1]))
                inter = iw * ih
                other_area = (other[2] - other[0]) * (other[3] - other[1])
                # The same pack, or a part of a pack (cap, label) inside a better box.
                if inter / (area + other_area - inter) > 0.3 or inter / min(area, other_area) > 0.6:
                    clear = False
                    break
            if clear:
                kept.append((all_boxes[i], float(all_scores[i])))
        return kept

    def look(self, image: np.ndarray, catalog: list[CatalogEntry]) -> list[Look]:
        """Every pack found in a BGR image, ours (with a product) or not. The photo is cleaned
        first (a photographed screen is straightened, colours and moire fixed); boxes are mapped
        back to the photo as given."""
        cfg = self.visual_config
        screen = cfg.screen_photos == "always" or (cfg.screen_photos == "auto" and is_screen_photo(image))
        cleaned = clean(image, cfg.screen_rectify, cfg.colour_normalise, cfg.demoire)
        looks = self._look(cleaned.image, catalog, screen)
        for look in looks:
            if cleaned.to_original is not None:
                look.box, outline = cleaned.box_to_original(look.box)
                look.polygon = outline if not look.polygon else cleaned.box_to_original(
                    _bounds(look.polygon))[1]
            look.evidence["cleaned"] = cleaned.steps
            look.evidence["screen_photo"] = screen
        return looks

    def _look(self, image: np.ndarray, catalog: list[CatalogEntry], screen: bool = False) -> list[Look]:
        cfg = self.visual_config
        accept_similarity = cfg.screen_similarity if screen else cfg.accept_similarity
        accept_colour = cfg.screen_colour if screen else cfg.accept_colour
        index = self.index_for(catalog)
        exact_future = self._pool.submit(self.exact.find, image, catalog)
        models = _Models.get()
        height, width = image.shape[:2]
        boxes = self._boxes(image, models) if len(index) else []
        crops = [image[int(b[1]):max(int(b[3]), int(b[1]) + 2), int(b[0]):max(int(b[2]), int(b[0]) + 2)]
                 for b, _ in boxes]
        embeddings = models.embed(crops)
        similarities = embeddings @ index.embeddings.T if crops else np.zeros((0, len(index)))
        brands = _brands(catalog)
        reads = _read_brands(models, embeddings, brands, index.embeddings, cfg.debias) if crops and brands             else [(None, 0.0)] * len(crops)
        owners = np.array(index.owners)
        looks: list[Look] = []
        for (box, detector_score), crop, row, (read, read_p) in zip(boxes, crops, similarities, reads):
            normalised = (float(box[0] / width), float(box[1] / height),
                          float((box[2] - box[0]) / width), float((box[3] - box[1]) / height))
            competitor = read if read is not None and not read.is_own else None
            if competitor is not None and read_p >= cfg.brand_read:
                # The pack says whose it is: a competitor brand name, read with confidence.
                looks.append(Look(normalised, round(min(0.99, read_p), 3), competitor.product_id, method="brand",
                                  evidence={"brand": competitor.brand, "brand_probability": round(read_p, 3),
                                            "detector": round(detector_score, 3)}))
                continue
            best: dict[str, tuple[float, int]] = {}
            for view, (value, owner) in enumerate(zip(row, owners)):
                if value > best.get(owner, (-2.0, 0))[0]:
                    best[owner] = (float(value), view)
            ranked = sorted(best.items(), key=lambda item: -item[1][0])
            product_id, (similarity, view) = ranked[0]
            colour = max(1 - cv2.compareHist(_colours(crop), index.colours[v], cv2.HISTCMP_BHATTACHARYYA)
                         for v, owner in enumerate(owners) if owner == product_id)
            ours = _sigmoid((similarity - accept_similarity) / 0.02) * min(1.0, colour / (accept_colour + 0.06))
            evidence = {"similarity": round(similarity, 3), "colour": round(float(colour), 3),
                        "detector": round(detector_score, 3),
                        "brand_read": read.brand if read is not None else None,
                        "brand_read_probability": round(read_p, 3), "brand_read_competitor": competitor is not None,
                        "alternatives": [{"product_id": p, "similarity": round(v, 3)} for p, (v, _) in ranked[:3]]}
            if similarity >= accept_similarity and colour >= accept_colour:
                # How clearly the best product beats its siblings (softmax over the top five).
                top = np.array([v for _, (v, _) in ranked[:5]])
                share = 1.0 / float(np.exp((top - top[0]) / 0.01).sum())
                looks.append(Look(normalised, round(min(0.99, ours * (0.55 + 0.45 * share)), 3), product_id,
                                  evidence=evidence))
            elif competitor is not None and read_p >= cfg.brand_name_other:
                looks.append(Look(normalised, round(read_p, 3), competitor.product_id, method="brand",
                                  evidence={**evidence, "brand": competitor.brand,
                                            "brand_probability": round(read_p, 3)}))
            elif detector_score >= cfg.other_threshold:
                looks.append(Look(normalised, round(max(0.5, min(0.9, 1 - ours)), 3), None,
                                  evidence={**evidence, "not_ours": True}))
        named_areas = [look.box[2] * look.box[3] for look in looks if look.product_id]
        if len(named_areas) >= 3:
            # Caps, labels and shelf strips the detector also boxes are much smaller than a pack.
            typical = float(np.median(named_areas))
            looks = [look for look in looks
                     if look.product_id or look.box[2] * look.box[3] >= cfg.other_min_size * typical]
        named = [look.box for look in looks if look.product_id]
        looks = [look for look in looks if look.product_id or all(_covered(look.box, box) < 0.3 for box in named)]
        exact: list[Match] = exact_future.result()
        for match in exact:
            if match.confidence < cfg.exact_confidence:
                continue
            overlapping = [look for look in looks if _iou(look.box, match.box) > 0.3]
            if any(look.method == "brand" and look.confidence >= 0.9 for look in overlapping):
                continue  # the pack's printed brand name outweighs a feature match on shared artwork
            for look in overlapping:
                looks.remove(look)
            looks.append(Look(match.box, max(match.confidence, *(l.confidence for l in overlapping if l.product_id),
                                              0.0), match.product_id, match.polygon, "exact",
                              {"inliers": match.inliers, "matches": match.matches}))
        return looks

    def analyze(self, image: bytes, catalog: list[CatalogEntry], own_manufacturer_id: str | None) -> ProviderResult:
        from .imaging import decode_upright

        array = decode_upright(image)
        if array is None:
            raise ValueError("Unable to decode image")
        by_id = {e.product_id: e for e in catalog}
        looks = self.look(array, catalog)
        detections = []
        for look in looks:
            entry = by_id.get(look.product_id or "")
            evidence = {"method": look.method, **look.evidence}
            if look.polygon:
                evidence["matcher"] = {"polygon": [list(p) for p in look.polygon]}
            if entry is not None:
                detections.append(ProviderDetection(*look.box, label="own" if entry.is_own else "competitor",
                                                    confidence=look.confidence, product_id=entry.product_id,
                                                    manufacturer_id=entry.manufacturer_id, evidence=evidence))
            else:
                detections.append(ProviderDetection(*look.box, label="competitor", confidence=look.confidence,
                                                    evidence=evidence))
        index = self.index_for(catalog)
        named = sum(1 for d in detections if d.product_id)
        return ProviderResult(
            detections=detections,
            warnings=[f"Packs are named by visual similarity to pack shots of {len(index.products)} catalogue "
                      "products; close variants of one design can be confused, and a pack that resembles none "
                      "of them is reported as not ours."],
            annotated_jpeg=annotate(array, detections, by_id),
            raw={"named": named, "not_ours": len(detections) - named, "index_products": len(index.products)},
        )
