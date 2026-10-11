"""Export human-reviewed shelf photos as training data.

Only photos whose every remaining detection was reviewed by a person are exported: a
partly reviewed photo has unlabelled boxes, which would teach a detector that real
products are background. Photos that appear in any evaluation manifest (by content hash)
are never exported, so the frozen holdout stays out of training.

Layout written under ``out``:
  facings/images/{train,val}/<capture>.<ext>   detector dataset (one class: product),
  facings/labels/{train,val}/<capture>.txt     YOLO "0 x_center y_center width height"
  facings/data.yaml
  crops/<SKU or _own-unidentified | _competitor-unidentified>/<detection>.jpg   SKU classifier dataset
  manifest.json                                 counts, origin, excluded holdout images
"""

from __future__ import annotations

import hashlib
import json
from collections import Counter
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from pathlib import Path

import cv2
import numpy as np
from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import DetectedObject, Organization, ShelfCapture
from .services import loaders
from .vision.pipeline import blob_store, latest_inference_ids

VAL_SHARE_MODULO = 5  # one photo in five goes to validation, chosen by a hash of its id


@dataclass(slots=True)
class ExportSummary:
    images: int = 0
    facings: int = 0
    skipped_partially_reviewed: int = 0
    skipped_holdout: int = 0
    classes: dict[str, int] = field(default_factory=dict)


def holdout_hashes(eval_dir: Path) -> set[str]:
    """sha256 of every image referenced by an evaluation manifest under ``eval_dir``."""
    hashes: set[str] = set()
    for manifest in eval_dir.rglob("manifest.json"):
        for item in json.loads(manifest.read_text(encoding="utf-8")).get("items", []):
            image = (manifest.parent / item["image"]).resolve()
            if image.is_file():
                hashes.add(hashlib.sha256(image.read_bytes()).hexdigest())
    return hashes


def export(session: Session, organization: Organization, out: Path, excluded: set[str]) -> ExportSummary:
    summary = ExportSummary()
    classes: Counter[str] = Counter()
    products = loaders.load_products(session, organization.id)
    captures = session.execute(select(ShelfCapture).where(
        ShelfCapture.organization_id == organization.id, ShelfCapture.status == "analysed",
        ShelfCapture.duplicate_of_id.is_(None)).order_by(ShelfCapture.uploaded_at)).scalars().all()
    latest = latest_inference_ids(session, [c.id for c in captures])
    store = blob_store()
    for capture in captures:
        if capture.id not in latest:
            continue
        if capture.sha256 in excluded:
            summary.skipped_holdout += 1
            continue
        detections = session.execute(select(DetectedObject).where(
            DetectedObject.inference_id == latest[capture.id])).scalars().all()
        live = [d for d in detections if d.verification != "rejected"]
        if not live or any(d.verification == "unverified" for d in live):
            summary.skipped_partially_reviewed += 1
            continue
        split = "val" if int(hashlib.sha256(capture.id.encode()).hexdigest()[:8], 16) % VAL_SHARE_MODULO == 0 else "train"
        data = store.get(capture.blob_key)
        extension = capture.blob_key.rsplit(".", 1)[-1]
        image_path = out / "facings" / "images" / split / f"{capture.id}.{extension}"
        label_path = out / "facings" / "labels" / split / f"{capture.id}.txt"
        image_path.parent.mkdir(parents=True, exist_ok=True)
        label_path.parent.mkdir(parents=True, exist_ok=True)
        image_path.write_bytes(data)
        label_path.write_text("".join(
            f"0 {d.x + d.width / 2:.6f} {d.y + d.height / 2:.6f} {d.width:.6f} {d.height:.6f}\n" for d in live),
            encoding="utf-8")
        array = cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_COLOR)
        height, width = array.shape[:2]
        for d in live:
            product = products.get(d.final_product_id or "")
            label = product.sku if product else f"_{d.final_label}-unidentified"
            x0, y0 = max(0, int(d.x * width)), max(0, int(d.y * height))
            x1, y1 = min(width, int((d.x + d.width) * width)), min(height, int((d.y + d.height) * height))
            if x1 <= x0 or y1 <= y0:
                continue
            ok, crop = cv2.imencode(".jpg", array[y0:y1, x0:x1], [int(cv2.IMWRITE_JPEG_QUALITY), 92])
            if ok:
                crop_path = out / "crops" / label / f"{d.id}.jpg"
                crop_path.parent.mkdir(parents=True, exist_ok=True)
                crop_path.write_bytes(crop.tobytes())
                classes[label] += 1
        summary.images += 1
        summary.facings += len(live)
    summary.classes = dict(sorted(classes.items()))
    (out / "facings").mkdir(parents=True, exist_ok=True)
    (out / "facings" / "data.yaml").write_text(
        "path: .\ntrain: images/train\nval: images/val\nnames:\n  0: product\n", encoding="utf-8")
    (out / "manifest.json").write_text(json.dumps({
        "organization": organization.slug, "data_origin": organization.data_origin,
        "exported_at": datetime.now(UTC).isoformat(), **asdict(summary),
        "note": "Only fully human-reviewed photos; evaluation-manifest images excluded.",
    }, indent=2), encoding="utf-8")
    return summary
