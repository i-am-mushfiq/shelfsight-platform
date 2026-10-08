"""Model evaluation against a frozen, versioned dataset manifest.

Manifest (JSON):
{
  "name": "...", "purpose": "smoke | holdout", "notes": "...",
  "items": [{
     "image": "relative/path.png",
     "slices": {"channel": "MT-SS", "lighting": "indoor", "device": "..."},
     "counts": {"total": 12, "own": 6, "rows": 3},            # count-level ground truth (optional)
     "boxes": [{"x":..,"y":..,"width":..,"height":.., "label": "own", "product_id": "..."}]  # optional
  }]
}

Box-level items give per-class precision/recall/F1 (IoU ≥ 0.5 greedy matching), a confusion
matrix and per-SKU accuracy; count-level items give count and share errors. Metrics are
reported overall and per slice. Aggregate accuracy alone is never the release criterion.
"""

from __future__ import annotations

import hashlib
import json
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

from .domain.shelf import assign_shelf_rows
from .vision.base import CatalogEntry, ProviderDetection, VisionProvider

IOU_THRESHOLD = 0.5


@dataclass(slots=True)
class EvalReport:
    dataset: str
    dataset_sha256: str
    purpose: str
    metrics: dict
    per_class: dict
    slices: dict
    items: list[dict]


def _iou(a: dict, b: ProviderDetection) -> float:
    ax2, ay2 = a["x"] + a["width"], a["y"] + a["height"]
    bx2, by2 = b.x + b.width, b.y + b.height
    iw = max(0.0, min(ax2, bx2) - max(a["x"], b.x))
    ih = max(0.0, min(ay2, by2) - max(a["y"], b.y))
    inter = iw * ih
    union = a["width"] * a["height"] + b.width * b.height - inter
    return inter / union if union else 0.0


def _match(truth: list[dict], predicted: list[ProviderDetection]) -> list[tuple[dict | None, ProviderDetection | None]]:
    pairs = sorted(((_iou(t, p), ti, pi) for ti, t in enumerate(truth) for pi, p in enumerate(predicted)), reverse=True)
    used_t, used_p, matches = set(), set(), []
    for iou, ti, pi in pairs:
        if iou < IOU_THRESHOLD:
            break
        if ti in used_t or pi in used_p:
            continue
        used_t.add(ti)
        used_p.add(pi)
        matches.append((truth[ti], predicted[pi]))
    matches += [(t, None) for i, t in enumerate(truth) if i not in used_t]
    matches += [(None, p) for i, p in enumerate(predicted) if i not in used_p]
    return matches


def _prf(tp: int, fp: int, fn: int) -> dict:
    precision = tp / (tp + fp) if tp + fp else None
    recall = tp / (tp + fn) if tp + fn else None
    f1 = 2 * precision * recall / (precision + recall) if precision and recall else None
    return {"tp": tp, "fp": fp, "fn": fn, "precision": precision, "recall": recall, "f1": f1}


def evaluate(provider: VisionProvider, manifest_path: Path, catalog: list[CatalogEntry] | None = None,
             own_manufacturer_id: str | None = None) -> EvalReport:
    raw = manifest_path.read_bytes()
    manifest = json.loads(raw)
    root = manifest_path.parent
    catalog = catalog or []
    class_counts: dict[str, dict[str, int]] = defaultdict(lambda: {"tp": 0, "fp": 0, "fn": 0})
    confusion: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    sku_hits = sku_total = 0
    slice_acc: dict[str, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    items = []
    for item in manifest["items"]:
        image = (root / item["image"]).read_bytes()
        result = provider.analyze(image, catalog, own_manufacturer_id)
        dets = result.detections
        own = sum(d.label == "own" for d in dets)
        _, rows = assign_shelf_rows([d.y + d.height / 2 for d in dets], [d.height for d in dets])
        entry: dict = {"image": item["image"], "predicted": {"total": len(dets), "own": own, "rows": rows,
                                                            "unknown": sum(d.label == "unknown" for d in dets)}}
        counts = item.get("counts")
        if counts:
            entry["count_error"] = {
                "total": len(dets) - counts["total"], "own": own - counts["own"],
                "rows": (rows - counts["rows"]) if "rows" in counts else None,
                "share_abs_error": round(abs((own / len(dets) if dets else 0) - counts["own"] / counts["total"]), 4),
            }
            for key, value in item.get("slices", {}).items():
                slice_acc[f"{key}={value}"]["share_abs_error"].append(entry["count_error"]["share_abs_error"])
        if item.get("boxes"):
            for truth, pred in _match(item["boxes"], dets):
                if truth and pred:
                    confusion[truth["label"]][pred.label] += 1
                    if truth["label"] == pred.label:
                        class_counts[truth["label"]]["tp"] += 1
                    else:
                        class_counts[truth["label"]]["fn"] += 1
                        class_counts[pred.label]["fp"] += 1
                    if truth.get("product_id"):
                        sku_total += 1
                        sku_hits += pred.product_id == truth["product_id"]
                elif truth:
                    confusion[truth["label"]]["missed"] += 1
                    class_counts[truth["label"]]["fn"] += 1
                elif pred:
                    confusion["background"][pred.label] += 1
                    class_counts[pred.label]["fp"] += 1
        items.append(entry)

    counted = [i for i in items if "count_error" in i]
    metrics = {
        "items": len(items),
        "count_items": len(counted),
        "mean_abs_total_count_error": _mean([abs(i["count_error"]["total"]) for i in counted]),
        "mean_abs_own_count_error": _mean([abs(i["count_error"]["own"]) for i in counted]),
        "mean_share_abs_error": _mean([i["count_error"]["share_abs_error"] for i in counted]),
        "rows_exact": _mean([1.0 if i["count_error"]["rows"] == 0 else 0.0 for i in counted if i["count_error"]["rows"] is not None]),
        "sku_accuracy_on_matched": round(sku_hits / sku_total, 4) if sku_total else None,
        "confusion": {k: dict(v) for k, v in confusion.items()},
    }
    return EvalReport(
        dataset=manifest["name"], dataset_sha256=hashlib.sha256(raw).hexdigest(),
        purpose=manifest.get("purpose", "unspecified"), metrics=metrics,
        per_class={label: _prf(**c) for label, c in class_counts.items()},
        slices={name: {k: _mean(v) for k, v in values.items()} for name, values in slice_acc.items()},
        items=items,
    )


def _mean(values: list[float]) -> float | None:
    return round(sum(values) / len(values), 4) if values else None
