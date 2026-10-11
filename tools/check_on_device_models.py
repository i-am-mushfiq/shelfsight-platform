"""Runs the on-device pipeline exactly as lib/recognition/on_device.dart does, from the bundle
in assets/recognition/ only, and reports share-of-shelf error and CPU time per image.

  python tools/check_on_device_models.py FMCG_Shelf_Test_Set_20 [more folders] [--screen]
"""

from __future__ import annotations

import base64
import json
import math
import os
import re
import sys
import time
from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort

BUNDLE = Path(__file__).resolve().parents[1] / "assets" / "recognition"


def half(b64: str) -> np.ndarray:
    return np.frombuffer(base64.b64decode(b64), dtype="<f2").astype(np.float32)


class Pipeline:
    def __init__(self, threads: int = 4) -> None:
        options = ort.SessionOptions()
        options.intra_op_num_threads = threads
        self.detector = ort.InferenceSession(str(BUNDLE / "detector.onnx"), options, providers=["CPUExecutionProvider"])
        self.embedder = ort.InferenceSession(str(BUNDLE / "embedder.onnx"), options, providers=["CPUExecutionProvider"])
        c = json.loads((BUNDLE / "catalog.json").read_text(encoding="utf-8"))
        self.c = c
        e = c["embedder"]
        self.dim, self.size, self.mean, self.std = e["dim"], e["size"], np.array(e["mean"]), np.array(e["std"])
        self.products = c["products"]
        self.view_product = np.array(c["views"]["product"])
        self.view_emb = half(c["views"]["embeddings"]).reshape(-1, self.dim)
        self.view_col = half(c["views"]["colours"]).reshape(-1, 144)
        self.brands = c["brands"]["names"]
        self.brand_emb = half(c["brands"]["embeddings"]).reshape(-1, self.dim)
        self.brand_bias = np.array(c["brands"]["bias"])
        self.brand_product = c["brands"]["product"]
        self.refs = {m: (half(r["embeddings"]).reshape(-1, self.dim), np.array(list(r["labels"])), r["k"])
                     for m, r in c.get("references", {}).items()}

    @staticmethod
    def stretch(rgb: np.ndarray) -> np.ndarray:
        out = rgb.copy()
        for ch in range(3):
            low, high = np.percentile(rgb[:, :, ch], (1, 99))
            if high - low >= 20:
                out[:, :, ch] = np.clip((rgb[:, :, ch].astype(np.float32) - low) * 255 / (high - low), 0, 255)
        return out

    def detect(self, rgb: np.ndarray, t: dict) -> list:
        h, w = rgb.shape[:2]
        scale = 640 / max(h, w)
        nw, nh = round(w * scale), round(h * scale)
        px, py = (640 - nw) // 2, (640 - nh) // 2
        canvas = np.full((640, 640, 3), 114, np.uint8)
        canvas[py:py + nh, px:px + nw] = cv2.resize(rgb, (nw, nh), interpolation=cv2.INTER_AREA)
        out = self.detector.run(None, {"images": (canvas / 255.0).transpose(2, 0, 1)[None].astype(np.float32)})[0][0]
        boxes = []
        for x0, y0, x1, y1, score, _ in out:
            if score < t["box"]:
                continue
            boxes.append([max(0, (x0 - px) / scale), max(0, (y0 - py) / scale), min(w, (x1 - px) / scale),
                          min(h, (y1 - py) / scale), float(score)])
        boxes.sort(key=lambda b: -b[4])
        kept, frame = [], w * h
        for b in boxes:
            area = (b[2] - b[0]) * (b[3] - b[1])
            if not .002 * frame <= area <= .85 * frame or b[2] - b[0] < 8 or b[3] - b[1] < 8:
                continue
            ok = True
            for k in kept:
                inter = max(0, min(b[2], k[2]) - max(b[0], k[0])) * max(0, min(b[3], k[3]) - max(b[1], k[1]))
                ka = (k[2] - k[0]) * (k[3] - k[1])
                if inter / (area + ka - inter) > .3 or inter / min(area, ka) > .6:
                    ok = False
                    break
            if ok:
                kept.append(b)
        return kept

    def clip_input(self, crop: np.ndarray) -> np.ndarray:
        h, w = crop.shape[:2]
        side = max(h, w)
        square = np.full((side, side, 3), 255, np.uint8)
        square[(side - h) // 2:(side - h) // 2 + h, (side - w) // 2:(side - w) // 2 + w] = crop
        rgb = cv2.resize(square, (self.size, self.size), interpolation=cv2.INTER_AREA)
        return (((rgb / 255.0) - self.mean) / self.std).transpose(2, 0, 1).astype(np.float32)

    @staticmethod
    def colours(crop_rgb: np.ndarray) -> np.ndarray:
        bgr = cv2.cvtColor(crop_rgb, cv2.COLOR_RGB2BGR)
        hsv = cv2.cvtColor(cv2.resize(bgr, (128, 128), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2HSV)
        mask = ((hsv[:, :, 2] < 245) | (hsv[:, :, 1] > 20)).astype(np.uint8)
        hist = cv2.calcHist([hsv], [0, 1], mask, [18, 8], [0, 180, 0, 256]).reshape(-1)
        return hist / max(hist.sum(), 1e-6)

    def recognize(self, bgr: np.ndarray, screen: bool) -> list:
        """Returns [(kind, name, box)] with kind "own" or "other" (box normalised x, y, w, h)."""
        mode = "screen" if screen else "clean"
        t = self.c["thresholds"][mode]
        scale = min(1.0, 1280 / max(bgr.shape[:2]))
        if scale < 1:
            bgr = cv2.resize(bgr, None, fx=scale, fy=scale, interpolation=getattr(cv2, os.environ.get("DECODE_INTERP", "INTER_AREA")))
        rgb = self.stretch(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))
        if t.get("demoire"):
            from retail_platform.vision.screen_photo import remove_moire
            rgb = cv2.cvtColor(remove_moire(cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)), cv2.COLOR_BGR2RGB)
        boxes = self.detect(rgb, t)
        h, w = rgb.shape[:2]
        crops = [rgb[int(b[1]):max(int(b[3]), int(b[1]) + 2), int(b[0]):max(int(b[2]), int(b[0]) + 2)] for b in boxes]
        if not crops:
            return []
        feats = np.concatenate([self.embedder.run(None, {"pixels": np.stack([self.clip_input(c) for c in crops[i:i + 16]])})[0]
                                for i in range(0, len(crops), 16)])
        feats /= np.linalg.norm(feats, axis=1, keepdims=True)
        sims = feats @ self.view_emb.T
        logits = 100 * feats @ self.brand_emb.T - self.brand_bias
        probs = np.exp(logits - logits.max(axis=1, keepdims=True))
        probs /= probs.sum(axis=1, keepdims=True)
        ref_emb, ref_lab, k = self.refs[mode]
        ref_sims = feats @ ref_emb.T
        looks = []
        for i, b in enumerate(boxes):
            per = {}
            for v, sv in enumerate(sims[i]):
                p = int(self.view_product[v])
                per[p] = max(per.get(p, -2), float(sv))
            product, similarity = max(per.items(), key=lambda kv: kv[1])
            hist = self.colours(crops[i])
            colour = max(1 - math.sqrt(max(0, 1 - float(np.sqrt(hist * self.view_col[v]).sum())))
                         for v in np.where(self.view_product == product)[0])
            rs = ref_sims[i]
            gs, go = float(rs[ref_lab == "S"].max()), float(rs[ref_lab == "O"].max())
            top = np.argsort(-rs)[:k]
            xvote = float((rs[top] * (ref_lab[top] == "X")).sum() / rs[top].sum())
            box = (b[0] / w, b[1] / h, (b[2] - b[0]) / w, (b[3] - b[1]) / h)
            if xvote >= t["fragment_vote"]:
                continue  # looks like a known fragment / background, not a pack
            best = int(probs[i].argmax())
            brand = self.brands[best] if best < len(self.brands) else None
            competitor = brand is not None and not self.products[self.brand_product[brand]]["is_own"]
            score = similarity + t["pack_weight"] * colour + t["reference_weight"] * (gs - go)
            if competitor and probs[i, best] >= t["brand_read"]:
                looks.append(("other", brand, box))
            elif score >= t["accept"]:
                looks.append(("own", self.products[product]["name"], box))
            elif b[4] >= t["other"]:
                looks.append(("other", None, box))
        return looks


def main() -> None:
    screen = "--screen" in sys.argv
    folders = [Path(a) for a in sys.argv[1:] if not a.startswith("--")]
    pipe = Pipeline()
    errors, times = [], []
    for folder in folders:
        for f in sorted(q for q in folder.rglob("*") if q.suffix in (".png", ".jpg")):
            img = cv2.imread(str(f))
            started = time.perf_counter()
            looks = pipe.recognize(img, screen)
            times.append(time.perf_counter() - started)
            own = sum(1 for kind, _, _ in looks if kind == "own")
            share = 100 * own / max(1, len(looks))
            target = int(re.search(r"(\d+)pct", f.name).group(1))
            errors.append(share - target)
            print(f"{f.name:40} target {target:3d}%  measured {share:5.1f}%  ({own} Square, {len(looks) - own} other)  "
                  f"{times[-1] * 1000:.0f} ms")
    e = np.array(errors)
    print(f"mean abs error {np.abs(e).mean():.1f} pts, median {np.median(np.abs(e)):.1f}, bias {e.mean():+.1f}; "
          f"{1000 * np.mean(times):.0f} ms/image on CPU (4 threads)")


if __name__ == "__main__":
    main()
