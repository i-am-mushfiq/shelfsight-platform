"""Business configuration and data ingestion. Rule changes are versioned: create a draft,
review it, then activate (which retires the previous version). Nothing is edited in place."""

from __future__ import annotations

import csv
import io
from datetime import date
from typing import Annotated, Any

from fastapi import APIRouter, Depends, File, Form, HTTPException, Response, UploadFile, status
from pydantic import BaseModel, Field
from sqlalchemy import func, select

from .. import audit
from ..models import (
    Brand,
    Category,
    Channel,
    CoreAssortmentItem,
    Manufacturer,
    OutletClass,
    Order,
    OrderItem,
    Outlet,
    PlacementRule,
    PortfolioTarget,
    Product,
    ProductPrice,
    ReferenceImage,
    RuleSet,
)
from ..security import Principal
from ..services import intelligence, reference_images
from .catalog import channel_out
from .live import forget_catalogs
from .deps import DB, require

router = APIRouter(prefix="/v2/admin", tags=["admin"])
RulesWriter = Annotated[Principal, Depends(require("rules:write"))]

ITEM_MODELS = {"portfolio": PortfolioTarget, "assortment": CoreAssortmentItem, "placement": PlacementRule}
ITEM_FIELDS = {
    "portfolio": {"channel_id", "outlet_class_id", "category_id", "dimension", "dimension_value", "target_share", "tolerance"},
    "assortment": {"channel_id", "outlet_class_id", "product_id", "min_facings", "priority"},
    "placement": {"channel_id", "category_id", "product_id", "brand_id", "manufacturer_id", "preferred_band",
                  "min_facings", "min_share_of_shelf", "priority", "promo_required", "description"},
}


def _items(session, rule_set: RuleSet) -> list[dict]:  # type: ignore[no-untyped-def]
    model = ITEM_MODELS[rule_set.kind]
    fields = ITEM_FIELDS[rule_set.kind]
    rows = session.execute(select(model).where(model.rule_set_id == rule_set.id)).scalars()
    return [{"id": r.id, **{f: getattr(r, f) for f in fields}} for r in rows]


@router.get("/rule-sets")
def list_rule_sets(principal: RulesWriter, session: DB, kind: str | None = None) -> list[dict]:
    query = select(RuleSet).where(RuleSet.organization_id == principal.organization_id)
    if kind:
        query = query.where(RuleSet.kind == kind)
    return [{"id": r.id, "kind": r.kind, "name": r.name, "version": r.version, "status": r.status,
             "effective_from": r.effective_from.isoformat() if r.effective_from else None, "notes": r.notes}
            for r in session.execute(query.order_by(RuleSet.kind, RuleSet.version)).scalars()]


@router.get("/rule-sets/{rule_set_id}")
def get_rule_set(rule_set_id: str, principal: RulesWriter, session: DB) -> dict:
    rule_set = session.get(RuleSet, rule_set_id)
    if rule_set is None or rule_set.organization_id != principal.organization_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Rule set not found")
    return {"id": rule_set.id, "kind": rule_set.kind, "name": rule_set.name, "version": rule_set.version,
            "status": rule_set.status, "items": _items(session, rule_set)}


class RuleSetIn(BaseModel):
    kind: str = Field(pattern="^(portfolio|assortment|placement)$")
    name: str = Field(min_length=3, max_length=200)
    notes: str | None = None
    items: list[dict[str, Any]] = Field(min_length=1)


def _validate_item(kind: str, item: dict[str, Any]) -> dict[str, Any]:
    unknown = set(item) - ITEM_FIELDS[kind]
    if unknown:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"Unknown fields for {kind}: {sorted(unknown)}")
    if kind == "portfolio":
        if item.get("dimension") not in {"brand", "category", "price_tier"}:
            raise HTTPException(422, "portfolio dimension must be brand | category | price_tier")
        if not 0 <= float(item.get("target_share", -1)) <= 1:
            raise HTTPException(422, "target_share must be between 0 and 1")
    if kind == "placement" and item.get("preferred_band", "any") not in {"top", "eye", "middle", "bottom", "any"}:
        raise HTTPException(422, "preferred_band must be top | eye | middle | bottom | any")
    if kind == "placement" and not item.get("description"):
        raise HTTPException(422, "placement rules need a human-readable description")
    if kind == "assortment" and not item.get("product_id"):
        raise HTTPException(422, "assortment items need product_id")
    return item


REFERENCES = {"channel_id": Channel, "outlet_class_id": OutletClass, "category_id": Category, "product_id": Product,
              "brand_id": Brand, "manufacturer_id": Manufacturer}


def _check_references(session, principal: Principal, item: dict[str, Any]) -> None:  # type: ignore[no-untyped-def]
    """A foreign key proves a row exists somewhere; it must also belong to this organization."""
    for field, model in REFERENCES.items():
        value = item.get(field)
        if value is None:
            continue
        row = session.get(model, value)
        if row is None or row.organization_id != principal.organization_id:
            raise HTTPException(422, f"Unknown {field}: {value}")
    if item.get("dimension") == "brand":
        brand = session.get(Brand, item.get("dimension_value"))
        if brand is None or brand.organization_id != principal.organization_id:
            raise HTTPException(422, "dimension_value must be a brand id for dimension=brand")


@router.post("/rule-sets", status_code=201)
def create_rule_set(body: RuleSetIn, principal: RulesWriter, session: DB) -> dict:
    latest = session.execute(select(func.max(RuleSet.version)).where(RuleSet.organization_id == principal.organization_id,
                                                                     RuleSet.kind == body.kind)).scalar() or 0
    rule_set = RuleSet(organization_id=principal.organization_id, data_origin=principal.data_origin, kind=body.kind,
                       name=body.name, version=latest + 1, status="draft", notes=body.notes)
    session.add(rule_set)
    session.flush()
    model = ITEM_MODELS[body.kind]
    for item in body.items:
        _check_references(session, principal, _validate_item(body.kind, item))
        session.add(model(organization_id=principal.organization_id, data_origin=principal.data_origin,
                          rule_set_id=rule_set.id, **item))
    audit.record(session, principal, "rules.create_draft", "rule_set", rule_set.id,
                 {"kind": body.kind, "version": rule_set.version, "items": len(body.items)})
    session.commit()
    return {"id": rule_set.id, "version": rule_set.version, "status": rule_set.status}


@router.post("/rule-sets/{rule_set_id}/activate")
def activate_rule_set(rule_set_id: str, principal: RulesWriter, session: DB) -> dict:
    rule_set = session.get(RuleSet, rule_set_id)
    if rule_set is None or rule_set.organization_id != principal.organization_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Rule set not found")
    if rule_set.status == "active":
        return {"id": rule_set.id, "status": "active"}
    retired = []
    for current in session.execute(select(RuleSet).where(RuleSet.organization_id == principal.organization_id,
                                                         RuleSet.kind == rule_set.kind, RuleSet.status == "active")).scalars():
        current.status = "retired"
        retired.append(current.id)
    rule_set.status = "active"
    rule_set.effective_from = date.today()
    audit.record(session, principal, "rules.activate", "rule_set", rule_set.id,
                 {"kind": rule_set.kind, "version": rule_set.version, "retired": retired})
    session.commit()
    return {"id": rule_set.id, "status": "active", "retired": retired}


class ProductIn(BaseModel):
    sku: str = Field(min_length=2, max_length=64)
    name: str = Field(min_length=2, max_length=300)
    name_bn: str | None = None
    brand_id: str
    category_id: str
    pack_size: float | None = Field(default=None, gt=0)
    pack_unit: str | None = Field(default=None, max_length=16)
    price_tier: str | None = None
    barcode: str | None = None
    mrp: float | None = Field(default=None, gt=0)
    trade_price: float | None = Field(default=None, gt=0)


@router.post("/products", status_code=201)
def create_product(body: ProductIn, session: DB, principal: Annotated[Principal, Depends(require("catalog:write"))]) -> dict:
    brand = session.get(Brand, body.brand_id)
    category = session.get(Category, body.category_id)
    if brand is None or brand.organization_id != principal.organization_id:
        raise HTTPException(422, "Unknown brand")
    if category is None or category.organization_id != principal.organization_id:
        raise HTTPException(422, "Unknown category")
    if session.execute(select(Product.id).where(Product.organization_id == principal.organization_id,
                                                Product.sku == body.sku)).first():
        raise HTTPException(409, "SKU already exists")
    product = Product(organization_id=principal.organization_id, data_origin=principal.data_origin, sku=body.sku,
                      name=body.name, name_bn=body.name_bn, brand_id=brand.id, manufacturer_id=brand.manufacturer_id,
                      category_id=category.id, pack_size=body.pack_size, pack_unit=body.pack_unit,
                      price_tier=body.price_tier, barcode=body.barcode)
    session.add(product)
    session.flush()
    for price_type, amount in (("mrp", body.mrp), ("trade", body.trade_price)):
        if amount:
            session.add(ProductPrice(organization_id=principal.organization_id, data_origin=principal.data_origin,
                                     product_id=product.id, price_type=price_type, amount=amount, effective_from=date.today()))
    audit.record(session, principal, "catalog.product_create", "product", product.id, body.model_dump())
    session.commit()
    return {"id": product.id, "sku": product.sku}


ORDER_COLUMNS = ["external_ref", "outlet_code", "order_date", "sku", "quantity", "unit_price"]


@router.post("/import/orders")
async def import_orders(session: DB, principal: Annotated[Principal, Depends(require("data:import"))],
                        file: UploadFile = File(...)) -> dict:
    """CSV import of secondary sales. One row per order line; rows sharing external_ref form one order.

    Validation is all-or-nothing per order: an order with any bad line is rejected and reported;
    existing external_refs are skipped (idempotent re-imports). Nothing is silently coerced.
    """
    text = (await file.read()).decode("utf-8-sig")
    reader = csv.DictReader(io.StringIO(text))
    missing = [c for c in ORDER_COLUMNS if c not in (reader.fieldnames or [])]
    if missing:
        raise HTTPException(422, f"Missing columns: {missing}")
    outlets = dict(session.execute(select(Outlet.code, Outlet.id).where(Outlet.organization_id == principal.organization_id)).all())
    products = {sku: (pid, own) for sku, pid, own in session.execute(
        select(Product.sku, Product.id, Product.manufacturer.has(is_own=True)).where(Product.organization_id == principal.organization_id))}
    existing = set(session.execute(select(Order.external_ref).where(Order.organization_id == principal.organization_id)).scalars())
    grouped: dict[str, list[tuple[int, dict]]] = {}
    for line_number, row in enumerate(reader, start=2):
        grouped.setdefault(row["external_ref"].strip(), []).append((line_number, row))
    errors: list[dict] = []
    created = skipped = 0
    for ref, rows in grouped.items():
        if not ref:
            errors.extend({"line": n, "error": "external_ref is empty"} for n, _ in rows)
            continue
        if ref in existing:
            skipped += 1
            continue
        problems = []
        parsed = []
        for n, row in rows:
            try:
                outlet_id = outlets[row["outlet_code"].strip()]
            except KeyError:
                problems.append({"line": n, "error": f"unknown outlet_code {row['outlet_code']!r}"})
                continue
            product = products.get(row["sku"].strip())
            if product is None:
                problems.append({"line": n, "error": f"unknown sku {row['sku']!r}"})
                continue
            if not product[1]:
                problems.append({"line": n, "error": f"sku {row['sku']!r} is a competitor product; orders contain own products only"})
                continue
            try:
                order_date = date.fromisoformat(row["order_date"].strip())
                quantity = int(row["quantity"])
                unit_price = float(row["unit_price"])
                if quantity <= 0 or unit_price < 0:
                    raise ValueError
            except ValueError:
                problems.append({"line": n, "error": "order_date must be YYYY-MM-DD, quantity > 0, unit_price >= 0"})
                continue
            parsed.append((outlet_id, order_date, product[0], quantity, unit_price))
        if problems:
            errors.extend({"external_ref": ref, **p} for p in problems)
            continue
        if len({(p[0], p[1]) for p in parsed}) != 1:
            errors.append({"external_ref": ref, "error": "all lines of an order must share outlet_code and order_date"})
            continue
        outlet_id, order_date = parsed[0][0], parsed[0][1]
        order = Order(organization_id=principal.organization_id, data_origin=principal.data_origin, outlet_id=outlet_id,
                      order_date=order_date, source="ingest", external_ref=ref, status="confirmed")
        for _, _, product_id, quantity, unit_price in parsed:
            order.items.append(OrderItem(organization_id=principal.organization_id, data_origin=principal.data_origin,
                                         product_id=product_id, quantity=quantity, unit_price=unit_price,
                                         line_value=round(quantity * unit_price, 2)))
        session.add(order)
        created += 1
    audit.record(session, principal, "data.import_orders", "sales_order", None,
                 {"created": created, "skipped_existing": skipped, "rejected_lines": len(errors), "file": file.filename})
    session.commit()
    return {"orders_created": created, "orders_skipped_existing": skipped, "errors": errors[:500],
            "errors_total": len(errors)}


@router.post("/classify")
def run_classification(session: DB, principal: Annotated[Principal, Depends(require("rules:write"))]) -> dict:
    written = intelligence.classify_outlets(session, principal.organization_id, principal.data_origin)
    audit.record(session, principal, "classification.run", "outlet_classification", None, {"written": written})
    session.commit()
    return {"assessments_written": written}


# --- store types / channel taxonomy -----------------------------------------------------------

ICON_PATTERN = "^[a-z][a-z0-9_-]{0,31}$"


class ChannelIn(BaseModel):
    code: str = Field(pattern="^[A-Z0-9][A-Z0-9_-]{0,31}$")
    name: str = Field(min_length=2, max_length=200)
    name_bn: str | None = Field(default=None, max_length=200)
    parent_id: str | None = None
    description: str | None = Field(default=None, max_length=500)
    is_store_type: bool = False
    sort_order: int = Field(default=0, ge=0, le=1000)
    icon: str | None = Field(default=None, pattern=ICON_PATTERN)
    units_per_facing: int | None = Field(default=None, ge=1, le=500)


@router.post("/channels", status_code=201)
def create_channel(body: ChannelIn, principal: RulesWriter, session: DB) -> dict:
    if session.execute(select(Channel.id).where(Channel.organization_id == principal.organization_id,
                                                Channel.code == body.code)).first():
        raise HTTPException(409, "Channel code already exists")
    parent = None
    if body.parent_id:
        parent = session.get(Channel, body.parent_id)
        if parent is None or parent.organization_id != principal.organization_id:
            raise HTTPException(422, "Unknown parent_id")
    channel = Channel(organization_id=principal.organization_id, data_origin=principal.data_origin,
                      path=(parent.path if parent else "/") + body.code.lower() + "/", **body.model_dump())
    session.add(channel)
    session.flush()
    audit.record(session, principal, "channel.create", "channel", channel.id, body.model_dump())
    session.commit()
    return channel_out(channel)


class ChannelPatch(BaseModel):
    name: str | None = Field(default=None, min_length=2, max_length=200)
    name_bn: str | None = Field(default=None, max_length=200)
    description: str | None = Field(default=None, max_length=500)
    is_store_type: bool | None = None
    is_active: bool | None = None
    sort_order: int | None = Field(default=None, ge=0, le=1000)
    icon: str | None = Field(default=None, pattern=ICON_PATTERN)
    units_per_facing: int | None = Field(default=None, ge=1, le=500)


@router.patch("/channels/{channel_id}")
def update_channel(channel_id: str, body: ChannelPatch, principal: RulesWriter, session: DB) -> dict:
    channel = session.get(Channel, channel_id)
    if channel is None or channel.organization_id != principal.organization_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Channel not found")
    changes = body.model_dump(exclude_unset=True)
    before = {key: getattr(channel, key) for key in changes}
    for key, value in changes.items():
        setattr(channel, key, value)
    audit.record(session, principal, "channel.update", "channel", channel.id, {"before": before, "after": changes})
    session.commit()
    return channel_out(channel)


# --- catalogue pack shots ----------------------------------------------------------------------

CatalogWriter = Annotated[Principal, Depends(require("catalog:write"))]


@router.post("/products/{product_id}/reference-images", status_code=201)
async def upload_reference_image(product_id: str, principal: CatalogWriter, session: DB, response: Response,
                                 image: UploadFile = File(...), view: str = Form("front")) -> dict:
    product = session.get(Product, product_id)
    if product is None or product.organization_id != principal.organization_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Product not found")
    data = await image.read(reference_images.MAX_BYTES + 1)
    try:
        result = reference_images.add_reference_image(session, principal.organization_id, principal.data_origin,
                                                      product, data, image.filename, view)
    except reference_images.ReferenceImageRejected as exc:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(exc)) from exc
    forget_catalogs()
    if result.created:
        audit.record(session, principal, "catalog.reference_image_add", "reference_image", result.image.id,
                     {"product_id": product.id, "sha256": result.image.sha256, "view": view})
    else:
        response.status_code = status.HTTP_200_OK
    session.commit()
    return reference_images.reference_out(result.image)


@router.delete("/reference-images/{image_id}", status_code=204)
def delete_reference_image(image_id: str, principal: CatalogWriter, session: DB) -> Response:
    image = session.get(ReferenceImage, image_id)
    if image is None or image.organization_id != principal.organization_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Reference image not found")
    audit.record(session, principal, "catalog.reference_image_delete", "reference_image", image.id,
                 {"product_id": image.product_id, "sha256": image.sha256})
    session.delete(image)
    session.commit()
    forget_catalogs()
    return Response(status_code=204)
