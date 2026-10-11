"""Live product lookup for the camera preview: one frame in, the catalogue products on it out.

Nothing is stored: this is a viewfinder aid. Photos the officer keeps go through the normal
capture pipeline. Uses the visual lookup (detector + CLIP) when installed, otherwise the
pack-shot matcher; neither calls an external service or needs training.
"""

from __future__ import annotations

import threading
import time
from dataclasses import replace
from typing import Annotated

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status

from ..config import get_settings
from ..security import Principal
from ..vision.base import CatalogEntry
from ..vision.imaging import decode_upright
from ..vision.pipeline import catalog_for
from ..vision.registry import get_live_matcher
from .deps import DB, require

router = APIRouter(prefix="/v2/live", tags=["live"])

CATALOG_TTL_SECONDS = 120
_catalogs: dict[tuple[str, str | None], tuple[float, list[CatalogEntry]]] = {}
_catalog_lock = threading.Lock()


def _catalog(session, organization_id: str, category_id: str | None, matcher) -> list[CatalogEntry]:  # type: ignore[no-untyped-def]
    """The catalogue with pack shots changes rarely; frames arrive several times a second."""
    key = (organization_id, category_id)
    with _catalog_lock:
        cached = _catalogs.get(key)
    if cached and time.monotonic() - cached[0] < CATALOG_TTL_SECONDS:
        return cached[1]
    catalog, _ = catalog_for(session, organization_id, category_id, provider=matcher)
    with _catalog_lock:
        _catalogs[key] = (time.monotonic(), catalog)
    return catalog


def forget_catalogs() -> None:
    with _catalog_lock:
        _catalogs.clear()


@router.post("/detect")
def detect(
    principal: Annotated[Principal, Depends(require("capture:write"))],
    session: DB,
    frame: UploadFile = File(...),
    category_id: str | None = Form(default=None),
) -> dict:
    data = frame.file.read(get_settings().max_upload_bytes + 1)
    if len(data) > get_settings().max_upload_bytes:
        raise HTTPException(status.HTTP_413_CONTENT_TOO_LARGE, "Frame is larger than the upload limit")
    image = decode_upright(data)
    if image is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Not a readable image")
    matcher = get_live_matcher()
    catalog = _catalog(session, principal.organization_id, category_id, matcher)
    started = time.perf_counter()
    index = matcher.index_for(catalog)
    looks = matcher.look(image, catalog)
    latency = round((time.perf_counter() - started) * 1000)
    by_id = {e.product_id: e for e in catalog}
    own_name = next((e.manufacturer.split()[0] for e in catalog if e.is_own), "ours")
    other = f"Not {own_name}"
    detections = []
    products: dict[str, dict] = {}
    for look in sorted(looks, key=lambda m: (round(m.box[1] * 4), m.box[0])):
        entry = by_id.get(look.product_id or "")
        if entry is not None and entry.name.endswith(" (any product)"):
            entry = replace(entry, name=entry.brand)  # a competitor brand read from the pack
        detections.append({
            "product_id": entry.product_id if entry else None, "sku": entry.sku if entry else None,
            "name": entry.name if entry else other, "brand": entry.brand if entry else None,
            "manufacturer": entry.manufacturer if entry else None, "is_own": bool(entry and entry.is_own),
            "confidence": look.confidence, "method": look.method,
            "box": dict(zip(("x", "y", "width", "height"), (round(v, 4) for v in look.box))),
            "polygon": [[round(x, 4), round(y, 4)] for x, y in look.polygon],
        })
        key = entry.product_id if entry else "other"
        product = products.setdefault(key, {
            "product_id": entry.product_id if entry else None, "name": entry.name if entry else other,
            "brand": entry.brand if entry else None, "is_own": bool(entry and entry.is_own),
            "facings": 0, "best_confidence": 0.0})
        product["facings"] += 1
        product["best_confidence"] = max(product["best_confidence"], look.confidence)
    return {
        "data_origin": principal.data_origin,
        "width": int(image.shape[1]), "height": int(image.shape[0]), "latency_ms": latency,
        "detections": detections,
        "summary": {"facings": len(detections), "own_facings": sum(d["is_own"] for d in detections),
                    "products": sorted(products.values(), key=lambda p: (-p["facings"], p["name"]))},
        "index": {"products": len(index.products), "views": len(index)},
        "matcher": matcher.version,
        "note": "Only products with catalogue pack shots can be named; a pack that looks like none of them "
                f"is shown as \"{other}\".",
    }
