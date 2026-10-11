"""Builds the on-device recognition bundle for the Flutter app (assets/recognition/):

  detector.onnx   SKU-110K YOLO11n (one class, "product"), NMS inside; 640x640 RGB in [0, 1]
  embedder.onnx   MobileCLIP image encoder; NxSxS RGB, CLIP-normalised; unnormalised features out
  catalog.json    products, one fingerprint (embedding) and colour histogram per pack-shot view,
                  brand-name text fingerprints with their pack-shot bias, and the thresholds

Fingerprints are computed with the exported embedder.onnx itself, so the phone and this
script give the same numbers. No training: every model is used as published.

  python tools/build_on_device_models.py --detector <sku110k-yolo11-n640.pt> \\
      --embedder MobileCLIP-S1 --pretrained datacompdr
"""

from __future__ import annotations

import argparse
import base64
import csv
import json
from pathlib import Path

import cv2
import numpy as np
import onnxruntime as ort
import torch

from retail_platform.services.sfbl_import import DEMO_COMPETITOR_BRANDS
from retail_platform.vision.packshot_matcher import split_packs
from retail_platform.vision.visual_lookup import _colours

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "recognition"
CATALOG = ROOT / "datasets" / "sfbl_catalog"


def export_detector(weights: str) -> None:
    from ultralytics import YOLO

    path = YOLO(weights).export(format="onnx", imgsz=640, nms=True, simplify=True, opset=17, conf=0.1, iou=0.5,
                                max_det=300)
    (OUT / "detector.onnx").write_bytes(Path(path).read_bytes())


def export_embedder(name: str, pretrained: str):  # type: ignore[no-untyped-def]
    import open_clip
    from timm.utils.model import reparameterize_model

    model, _, preprocess = open_clip.create_model_and_transforms(name, pretrained=pretrained)
    model = reparameterize_model(model.eval())
    size = model.visual.image_size if isinstance(model.visual.image_size, int) else model.visual.image_size[0]
    norm = [t for t in preprocess.transforms if t.__class__.__name__ == "Normalize"]
    mean = list(norm[0].mean) if norm else [0.0, 0.0, 0.0]
    std = list(norm[0].std) if norm else [1.0, 1.0, 1.0]

    class Image(torch.nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.visual = model.visual

        def forward(self, pixels: torch.Tensor) -> torch.Tensor:
            return self.visual(pixels)

    path = OUT / "embedder.onnx"
    torch.onnx.export(Image().eval(), torch.zeros(2, 3, size, size), str(path), input_names=["pixels"],
                      output_names=["features"], dynamic_axes={"pixels": {0: "n"}, "features": {0: "n"}},
                      opset_version=17, dynamo=False)
    tokenizer = open_clip.get_tokenizer(name)
    return model, tokenizer, size, mean, std


def clip_input(crop: np.ndarray, size: int, mean, std) -> np.ndarray:  # type: ignore[no-untyped-def]
    """Same as the app: pad to a white square, resize, normalise."""
    h, w = crop.shape[:2]
    side = max(h, w)
    square = np.full((side, side, 3), 255, np.uint8)
    square[(side - h) // 2:(side - h) // 2 + h, (side - w) // 2:(side - w) // 2 + w] = crop
    rgb = cv2.resize(cv2.cvtColor(square, cv2.COLOR_BGR2RGB), (size, size), interpolation=cv2.INTER_AREA)
    return (((rgb / 255.0) - np.array(mean)) / np.array(std)).transpose(2, 0, 1).astype(np.float32)


def b64(array: np.ndarray) -> str:
    return base64.b64encode(np.ascontiguousarray(array, dtype=np.float16).tobytes()).decode()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--detector", required=True)
    parser.add_argument("--embedder", default="MobileCLIP-S1")
    parser.add_argument("--pretrained", default="datacompdr")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)

    export_detector(args.detector)
    model, tokenizer, size, mean, std = export_embedder(args.embedder, args.pretrained)
    session = ort.InferenceSession(str(OUT / "embedder.onnx"), providers=["CPUExecutionProvider"])

    products, views, crops = [], [], []
    for row in csv.DictReader(open(CATALOG / "products.csv", encoding="utf-8")):
        files = [f.strip() for f in row["local_images"].split("|") if f.strip() and "_desc" not in f]
        if not files:
            continue
        brand = row["brand"] if row["brand"] != "Unlisted" else "Square Food (other)"
        products.append({"sku": f"SFBL-{int(row['pid']):03d}", "name": row["name"], "brand": brand,
                         "manufacturer": "Square Food & Beverage", "is_own": True})
        for name in files:
            for crop in split_packs((CATALOG / name).read_bytes()):
                if min(crop.shape[:2]) >= 16:
                    crops.append(crop)
                    views.append(len(products) - 1)
    for brand in DEMO_COMPETITOR_BRANDS:
        products.append({"sku": f"DEMO-{brand.upper().replace(' ', '-')}", "name": brand, "brand": brand,
                         "manufacturer": brand, "is_own": False})

    features = np.concatenate([
        session.run(None, {"pixels": np.stack([clip_input(c, size, mean, std) for c in crops[i:i + 32]])})[0]
        for i in range(0, len(crops), 32)
    ])
    features /= np.linalg.norm(features, axis=1, keepdims=True)
    colours = np.stack([_colours(c).reshape(-1) for c in crops])

    # Brand names the app tries to read on a pack: every brand, plus a neutral prompt.
    brands = sorted({p["brand"] for p in products if not p["brand"].lower().startswith("square food")})
    prompts = [f'a product package with the brand name "{b}"' for b in brands] + ["a product package with Bengali writing"]
    with torch.no_grad():
        text = model.encode_text(tokenizer(prompts)).float()
    text = torch.nn.functional.normalize(text, dim=-1).numpy()
    bias = (100.0 * features @ text.T).mean(axis=0)  # each prompt's average score on the pack shots

    catalog = {
        "version": 1,
        "embedder": {"name": args.embedder, "pretrained": args.pretrained, "size": size, "mean": mean, "std": std,
                     "dim": int(features.shape[1])},
        "detector": {"name": Path(args.detector).name, "size": 640},
        "products": products,
        "views": {"product": views, "embeddings": b64(features), "colours": b64(colours),
                  "colour_bins": [18, 8]},
        "brands": {"names": brands, "embeddings": b64(text), "bias": [round(float(b), 4) for b in bias],
                   "product": {b: next(i for i, p in enumerate(products) if p["brand"] == b) for b in brands}},
        # Tuned for SKU-110K YOLO11n + MobileCLIP-S1 on FMCG_Shelf_Test_Set_20 (clean images) and
        # simulated phone photos of them on a monitor (screen).
        "thresholds": {
            "clean": {"box": 0.1, "other": 0.35, "similarity": 0.49, "colour": 0.44, "brand_read": 0.95},
            "screen": {"box": 0.1, "other": 0.135, "similarity": 0.62, "colour": 0.24, "brand_read": 0.75},
        },
    }
    (OUT / "catalog.json").write_text(json.dumps(catalog), encoding="utf-8")
    for f in sorted(OUT.iterdir()):
        print(f"{f.name}: {f.stat().st_size / 1e6:.1f} MB")
    print(f"{len(products)} products, {len(views)} views, {len(brands)} brands, embedding {features.shape[1]}-d")


if __name__ == "__main__":
    main()
