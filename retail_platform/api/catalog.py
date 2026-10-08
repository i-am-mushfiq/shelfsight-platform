from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy import select

from ..models import Brand, Category, Channel, ClassScheme, Manufacturer, OutletClass, Product, Territory
from ..security import Principal
from ..services import loaders
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
    return [{"id": p.id, "sku": p.sku, "name": p.name, "brand_id": p.brand_id, "brand": p.brand_name,
             "manufacturer_id": p.manufacturer_id, "manufacturer": p.manufacturer_name, "is_own": p.is_own,
             "category_id": p.category_id, "category": p.category_name, "pack_size": p.pack_size, "pack_unit": p.pack_unit,
             "price_tier": p.price_tier, "mrp": p.mrp, "trade_price": p.trade_price, "barcode": barcodes.get(p.id),
             "is_active": p.is_active}
            for p in sorted(rows, key=lambda p: (not p.is_own, p.category_name, p.name))[:limit]]


@router.get("/channels")
def channels(principal: Reader, session: DB) -> list[dict]:
    rows = session.execute(select(Channel).where(Channel.organization_id == principal.organization_id).order_by(Channel.path)).scalars()
    return [{"id": c.id, "code": c.code, "name": c.name, "name_bn": c.name_bn, "parent_id": c.parent_id, "path": c.path,
             "is_active": c.is_active} for c in rows]


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
