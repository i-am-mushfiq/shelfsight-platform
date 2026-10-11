"""Catalogue pack shots: the images recognisers compare shelf facings against."""

from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..models import Product, ReferenceImage
from ..storage import reference_key, sha256
from ..vision.pipeline import blob_store

EXTENSIONS = {"jpg": "jpg", "jpeg": "jpg", "png": "png", "webp": "webp"}
VIEWS = {"front", "back", "side", "top", "angle"}
MAX_BYTES = 8 * 1024 * 1024


class ReferenceImageRejected(ValueError):
    pass


@dataclass(slots=True)
class AddResult:
    image: ReferenceImage
    created: bool


def add_reference_image(session: Session, organization_id: str, data_origin: str, product: Product,
                        data: bytes, filename: str | None, view: str = "front") -> AddResult:
    if view not in VIEWS:
        raise ReferenceImageRejected(f"view must be one of {sorted(VIEWS)}")
    if len(data) > MAX_BYTES:
        raise ReferenceImageRejected("Image is larger than 8 MB")
    extension = EXTENSIONS.get((filename or "").lower().rsplit(".", 1)[-1], "jpg")
    if cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_COLOR) is None:
        raise ReferenceImageRejected("Not a readable image")
    digest = sha256(data)
    existing = session.execute(select(ReferenceImage).where(ReferenceImage.product_id == product.id,
                                                            ReferenceImage.sha256 == digest)).scalar_one_or_none()
    if existing is not None:
        return AddResult(existing, created=False)
    key = reference_key(organization_id, digest, extension)
    store = blob_store()
    if not store.exists(key):
        store.put(key, data)
    image = ReferenceImage(organization_id=organization_id, data_origin=data_origin, product_id=product.id,
                           blob_key=key, sha256=digest, view=view)
    session.add(image)
    session.flush()
    return AddResult(image, created=True)


def reference_out(image: ReferenceImage) -> dict:
    return {"id": image.id, "product_id": image.product_id, "view": image.view, "sha256": image.sha256,
            "image_url": f"/v2/catalog/reference-images/{image.id}/image", "created_at": image.created_at.isoformat()}
