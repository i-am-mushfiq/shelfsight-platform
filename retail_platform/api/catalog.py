from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from sqlalchemy import func, select

from ..models import (
    Brand,
    Category,
    Channel,
    ClassScheme,
    Manufacturer,
    OutletClass,
    Product,
    ReferenceImage,
    Territory,
)
from ..security import Principal
from ..services import loaders, ordering
from ..services.reference_images import reference_out
from ..vision.pipeline import blob_store
from .deps import DB, require

router = APIRouter(prefix="/v2/catalog", tags=["catalog"])
Reader = Annotated[Principal, Depends(require("catalog:read"))]


@router.get("/manufacturers")
def manufacturers(principal: Reader, session: DB) -> list[dict]:
    rows = session.execute(select(Manufacturer).where(Manufacturer.organization_id == principal.organization_id)
                           .order_by(Manufacturer.is_own.desc(), Manufacturer.name)).scalars()
    return [{"id": m.id, "code": m.code, "name": m.name, "is_own": m.is_own, "is_verified": m.is_verified} for m in rows]


@router.get("/brands")
def brands(principal: Reader, session: DB) -> list[dict]:
    rows = session.execute(select(Brand).where(Brand.organization_id == principal.organization_id).order_by(Brand.name)).scalars()
    return [{"id": b.id, "code": b.code, "name": b.name, "name_bn": b.name_bn, "manufacturer_id": b.manufacturer_id,
             "parent_id": b.parent_id} for b in rows]


@router.get("/categories")
def categories(principal: Reader, session: DB) -> list[dict]:
    rows = session.execute(select(Category).where(Category.organization_id == principal.organization_id).order_by(Category.path)).scalars()
    return [{"id": c.id, "code": c.code, "name": c.name, "name_bn": c.name_bn, "parent_id": c.parent_id,
             "path": c.path, "level": c.level} for c in rows]


@router.get("/products")
def products(principal: Reader, session: DB, own: bool | None = None, category: str | None = None,
             q: str | None = None, include_inactive: bool = False, limit: int = Query(500, le=2000)) -> list[dict]:
    infos = loaders.load_products(session, principal.organization_id)
    rows = list(infos.values())
    if own is not None:
        rows = [p for p in rows if p.is_own == own]
    if category:
        cat = session.execute(select(Category).where(Category.organization_id == principal.organization_id,
                                                     Category.code == category)).scalar_one_or_none()
        allowed = loaders.category_descendants(session, principal.organization_id).get(cat.id, set()) if cat else set()
        rows = [p for p in rows if p.category_id in allowed]
    if q:
        needle = q.lower()
        rows = [p for p in rows if needle in p.name.lower() or needle in p.sku.lower()]
    if not include_inactive:
        rows = [p for p in rows if p.is_active]
    barcodes = dict(session.execute(select(Product.id, Product.barcode).where(Product.organization_id == principal.organization_id)).all())
    references = dict(session.execute(select(ReferenceImage.product_id, func.count()).where(
        ReferenceImage.organization_id == principal.organization_id).group_by(ReferenceImage.product_id)).all())
    return [{"id": p.id, "sku": p.sku, "name": p.name, "brand_id": p.brand_id, "brand": p.brand_name,
             "manufacturer_id": p.manufacturer_id, "manufacturer": p.manufacturer_name, "is_own": p.is_own,
             "category_id": p.category_id, "category": p.category_name, "pack_size": p.pack_size, "pack_unit": p.pack_unit,
             "price_tier": p.price_tier, "mrp": p.mrp, "trade_price": p.trade_price, "barcode": barcodes.get(p.id),
             "order_multiple": p.order_multiple, "reference_images": references.get(p.id, 0), "is_active": p.is_active}
            for p in sorted(rows, key=lambda p: (not p.is_own, p.category_name, p.name))[:limit]]


@router.get("/products/{product_id}/reference-images")
def product_reference_images(product_id: str, principal: Reader, session: DB) -> list[dict]:
    product = session.get(Product, product_id)
    if product is None or product.organization_id != principal.organization_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Product not found")
    rows = session.execute(select(ReferenceImage).where(ReferenceImage.product_id == product.id)
                           .order_by(ReferenceImage.created_at)).scalars()
    return [reference_out(r) for r in rows]


@router.get("/reference-images/{image_id}/image")
def reference_image(image_id: str, principal: Reader, session: DB) -> Response:
    image = session.get(ReferenceImage, image_id)
    if image is None or image.organization_id != principal.organization_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Reference image not found")
    extension = image.blob_key.rsplit(".", 1)[-1]
    return Response(blob_store().get(image.blob_key), media_type=f"image/{'jpeg' if extension == 'jpg' else extension}",
                    headers={"Cache-Control": "private, max-age=86400"})


def channel_out(channel: Channel) -> dict:
    return {"id": channel.id, "code": channel.code, "name": channel.name, "name_bn": channel.name_bn,
            "parent_id": channel.parent_id, "path": channel.path, "description": channel.description,
            "is_active": channel.is_active, "is_store_type": channel.is_store_type, "sort_order": channel.sort_order,
            "icon": channel.icon, "units_per_facing": channel.units_per_facing}


@router.get("/channels")
def channels(principal: Reader, session: DB) -> list[dict]:
    rows = session.execute(select(Channel).where(Channel.organization_id == principal.organization_id).order_by(Channel.path)).scalars()
    return [channel_out(c) for c in rows]


@router.get("/store-types")
def store_types(principal: Reader, session: DB) -> list[dict]:
    """The store types an officer chooses from when starting a visit, in display order."""
    rows = session.execute(select(Channel).where(
        Channel.organization_id == principal.organization_id, Channel.is_store_type.is_(True),
        Channel.is_active.is_(True)).order_by(Channel.sort_order, Channel.name)).scalars().all()
    parents = {c.id: c.name for c in session.execute(select(Channel).where(
        Channel.id.in_({r.parent_id for r in rows if r.parent_id}))).scalars()}
    return [{**channel_out(c), "parent": parents.get(c.parent_id or ""),
             "effective_units_per_facing": ordering.units_per_facing(session, c.id)} for c in rows]


@router.get("/territories")
def territories(principal: Reader, session: DB) -> list[dict]:
    rows = session.execute(select(Territory).where(Territory.organization_id == principal.organization_id).order_by(Territory.path)).scalars()
    return [{"id": t.id, "code": t.code, "name": t.name, "kind": t.kind, "parent_id": t.parent_id, "path": t.path} for t in rows]


@router.get("/outlet-classes")
def outlet_classes(principal: Reader, session: DB) -> dict:
    scheme = loaders.active_scheme(session, principal.organization_id)
    if scheme is None:
        return {"scheme": None, "classes": []}
    rows = session.execute(select(OutletClass).where(OutletClass.scheme_id == scheme.id).order_by(OutletClass.rank)).scalars()
    return {"scheme": {"id": scheme.id, "code": scheme.code, "name": scheme.name, "version": scheme.version,
                       "description": scheme.description},
            "classes": [{"id": c.id, "code": c.code, "label": c.label, "rank": c.rank, "criteria": c.criteria} for c in rows]}


__all__ = ["router", "ClassScheme"]
