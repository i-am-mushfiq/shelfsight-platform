from __future__ import annotations

from dataclasses import asdict
from datetime import date, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError

from .. import audit
from ..domain import call_prep, orders as order_domain
from ..models import (
    Channel,
    CompetitorObservation,
    Manufacturer,
    Order,
    OrderItem,
    Outlet,
    OutletClass,
    Product,
    Promotion,
    PromotionProduct,
    Recommendation,
    RecommendationFeedback,
    Territory,
    Visit,
)
from ..observability import RECOMMENDATION_FEEDBACK
from ..security import Principal, scoped_outlets
from ..services import intelligence, loaders
from .deps import DB, outlet_or_404, require

router = APIRouter(prefix="/v2", tags=["outlets"])

Reader = Annotated[Principal, Depends(require("outlet:read"))]


class OutletSummary(BaseModel):
    id: str
    code: str
    name: str
    name_bn: str | None
    address: str | None
    lat: float | None
    lng: float | None
    channel: str
    channel_code: str
    territory: str
    class_code: str | None
    class_label: str | None
    last_visit_at: str | None
    open_recommendations: int
    data_origin: str


def _summaries(session, principal: Principal, outlets: list[Outlet]) -> list[OutletSummary]:  # type: ignore[no-untyped-def]
    ids = [o.id for o in outlets]
    channels = {c.id: c for c in session.execute(select(Channel).where(Channel.organization_id == principal.organization_id)).scalars()}
    territories = dict(session.execute(select(Territory.id, Territory.name).where(Territory.organization_id == principal.organization_id)).all())
    last_visit = dict(session.execute(
        select(Visit.outlet_id, func.max(Visit.started_at)).where(Visit.outlet_id.in_(ids)).group_by(Visit.outlet_id)).all())
    open_recs = dict(session.execute(
        select(Recommendation.outlet_id, func.count()).where(Recommendation.outlet_id.in_(ids), Recommendation.status == "open")
        .group_by(Recommendation.outlet_id)).all())
    scheme = loaders.active_scheme(session, principal.organization_id)
    classes = loaders.effective_classifications(session, principal.organization_id, scheme.id if scheme else None)
    class_rows = {c.id: c for c in session.execute(select(OutletClass).where(OutletClass.organization_id == principal.organization_id)).scalars()}
    result = []
    for outlet in outlets:
        assessment = classes.get(outlet.id)
        cls = class_rows.get(assessment.class_id) if assessment else None
        channel = channels[outlet.channel_id]
        result.append(OutletSummary(
            id=outlet.id, code=outlet.code, name=outlet.name, name_bn=outlet.name_bn, address=outlet.address,
            lat=outlet.lat, lng=outlet.lng, channel=channel.name, channel_code=channel.code,
            territory=territories.get(outlet.territory_id, ""), class_code=cls.code if cls else None,
            class_label=cls.label if cls else None,
            last_visit_at=last_visit[outlet.id].isoformat() if outlet.id in last_visit else None,
            open_recommendations=open_recs.get(outlet.id, 0), data_origin=outlet.data_origin,
        ))
    return result


@router.get("/outlets", response_model=list[OutletSummary])
def list_outlets(
    principal: Reader, session: DB,
    q: str | None = None, channel: str | None = None, territory: str | None = None,
    limit: int = Query(200, le=1000), offset: int = 0,
) -> list[OutletSummary]:
    query = scoped_outlets(session, principal).where(Outlet.is_active.is_(True))
    if q:
        query = query.where(Outlet.name.ilike(f"%{q}%") | Outlet.code.ilike(f"%{q}%"))
    if channel:
        query = query.join(Channel, Channel.id == Outlet.channel_id).where(Channel.code == channel)
    if territory:
        query = query.join(Territory, Territory.id == Outlet.territory_id).where(Territory.code == territory)
    outlets = session.execute(query.order_by(Outlet.name).limit(limit).offset(offset)).scalars().all()
    return _summaries(session, principal, list(outlets))


@router.get("/outlets/{outlet_id}", response_model=OutletSummary)
def get_outlet(outlet_id: str, principal: Reader, session: DB) -> OutletSummary:
    return _summaries(session, principal, [outlet_or_404(session, principal, outlet_id)])[0]


# --- intelligence --------------------------------------------------------------------------------


def recommendation_out(rec: Recommendation, products: dict) -> dict:  # type: ignore[type-arg]
    product = products.get(rec.product_id) if rec.product_id else None
    return {
        "id": rec.id, "type": rec.type, "status": rec.status, "action": rec.action, "reason": rec.reason,
        "evidence": rec.evidence, "expected_impact": rec.expected_impact,
        "suggested_quantity": rec.suggested_quantity, "confidence": rec.confidence, "priority": rec.priority,
        "source": rec.source, "generator_version": rec.generator_version,
        "product": {"id": product.id, "sku": product.sku, "name": product.name} if product else None,
        "created_at": rec.created_at.isoformat(), "data_origin": rec.data_origin,
        "disclaimer": "Recommendation, not fact: based on the evidence shown.",
    }


@router.post("/outlets/{outlet_id}/intelligence:refresh")
def refresh_intelligence(outlet_id: str, principal: Reader, session: DB, as_of: date | None = None) -> dict:
    """Compute outlet intelligence now, store score history and sync recommendations (idempotent)."""
    outlet_or_404(session, principal, outlet_id)
    if as_of and principal.data_origin != "synthetic":
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "as_of is only allowed for synthetic data")
    intel = intelligence.analyze(session, principal.organization_id, outlet_id, as_of)
    recs = intelligence.persist(session, principal.organization_id, intel, principal.data_origin,
                                intel.latest_visit["id"] if intel.latest_visit else None)
    session.commit()
    products = loaders.load_products(session, principal.organization_id, intel.as_of)
    return serialize_intelligence(intel, recs, products, principal.data_origin)


def serialize_intelligence(intel: intelligence.OutletIntelligence, recs: list[Recommendation], products: dict,
                           data_origin: str) -> dict:  # type: ignore[type-arg]
    p = intel.portfolio

    def names(product_id: str | None) -> dict | None:
        product = products.get(product_id) if product_id else None
        return {"id": product.id, "sku": product.sku, "name": product.name, "brand": product.brand_name,
                "category": product.category_name} if product else None

    return {
        "data_origin": data_origin,
        "outlet": {"id": intel.outlet.id, "code": intel.outlet.code, "name": intel.outlet.name,
                   "class": intel.outlet.class_label},
        "as_of": intel.as_of.isoformat(),
        "classification": intel.classification,
        "scores": [asdict(s) for s in intel.scores],
        "portfolio": {
            "window": p.window, "generator_version": p.generator_version, "totals": p.totals,
            "basis": "own-brand secondary sales (company order data contains own products only)",
            "current_mix": {k: [asdict(e) for e in v] for k, v in p.current_mix.items()},
            "target_mix": p.target_mix,
            "channel_benchmark": {k: [asdict(e) for e in v] for k, v in p.channel_benchmark.items()},
            "peer_benchmark": {k: [asdict(e) for e in v] for k, v in p.peer_benchmark.items()},
            "peer_group": p.peer_group,
            "skus": [{**asdict(s), "product": names(s.product_id)} for s in p.sku_stats],
            "gaps": [{**asdict(g), "product": names(g.product_id)} for g in p.gaps],
        },
        "shelf": intel.shelf,
        "latest_visit": intel.latest_visit,
        "placement": {"score": intel.placement_score, "results": intel.placement},
        "competition": {"presence": intel.competitors, "price_positioning": intel.price_positioning},
        "recommendations": [recommendation_out(r, products) for r in recs],
        "rule_sets": intel.rule_sets,
    }


@router.get("/outlets/{outlet_id}/recommendations")
def list_recommendations(outlet_id: str, principal: Reader, session: DB, status_filter: str = Query("open", alias="status")) -> list[dict]:
    outlet_or_404(session, principal, outlet_id)
    query = select(Recommendation).where(Recommendation.outlet_id == outlet_id)
    if status_filter != "all":
        query = query.where(Recommendation.status == status_filter)
    recs = session.execute(query.order_by(Recommendation.priority, Recommendation.confidence.desc())).scalars().all()
    products = loaders.load_products(session, principal.organization_id)
    return [recommendation_out(r, products) for r in recs]


class FeedbackIn(BaseModel):
    decision: str = Field(pattern="^(accepted|modified|rejected)$")
    modified_quantity: int | None = Field(default=None, ge=0)
    note: str | None = Field(default=None, max_length=1000)


@router.post("/recommendations/{recommendation_id}/feedback")
def recommendation_feedback(recommendation_id: str, body: FeedbackIn, session: DB,
                            principal: Annotated[Principal, Depends(require("recommendation:feedback"))]) -> dict:
    rec = session.get(Recommendation, recommendation_id)
    if rec is None or rec.organization_id != principal.organization_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Recommendation not found")
    outlet_or_404(session, principal, rec.outlet_id)
    if rec.status not in {"open", "accepted", "modified"}:
        raise HTTPException(status.HTTP_409_CONFLICT, f"Recommendation is {rec.status}")
    if body.decision == "modified" and body.modified_quantity is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "modified requires modified_quantity")
    session.add(RecommendationFeedback(organization_id=principal.organization_id, data_origin=rec.data_origin,
                                       recommendation_id=rec.id, user_id=principal.user_id,
                                       decision=body.decision, modified_quantity=body.modified_quantity, note=body.note))
    previous = rec.status
    rec.status = body.decision
    if body.decision == "modified":
        rec.suggested_quantity = body.modified_quantity
    audit.record(session, principal, "recommendation.feedback", "recommendation", rec.id,
                 {"from": previous, "to": body.decision, "quantity": body.modified_quantity})
    session.commit()
    RECOMMENDATION_FEEDBACK.labels(rec.type, body.decision).inc()
    return {"id": rec.id, "status": rec.status}


# --- orders ----------------------------------------------------------------------------------


def _active_promotions(session, organization_id: str, channel_path: str, today: date) -> list[tuple[Promotion, list[str]]]:  # type: ignore[no-untyped-def]
    channel_paths = dict(session.execute(select(Channel.id, Channel.path).where(Channel.organization_id == organization_id)).all())
    promos = session.execute(select(Promotion).where(Promotion.organization_id == organization_id,
                                                     Promotion.starts_on <= today, Promotion.ends_on >= today)).scalars()
    result = []
    for promo in promos:
        if promo.channel_id and not channel_path.startswith(channel_paths.get(promo.channel_id, "\x00")):
            continue
        product_ids = list(session.execute(select(PromotionProduct.product_id).where(PromotionProduct.promotion_id == promo.id)).scalars())
        result.append((promo, product_ids))
    return result


@router.get("/outlets/{outlet_id}/suggested-order")
def suggested_order(outlet_id: str, principal: Reader, session: DB) -> dict:
    outlet = outlet_or_404(session, principal, outlet_id)
    today = date.today()
    products = loaders.load_products(session, principal.organization_id, today)
    lines = loaders.load_order_lines(session, principal.organization_id, today - timedelta(days=120))
    recs = session.execute(select(Recommendation).where(Recommendation.outlet_id == outlet_id,
                                                        Recommendation.status.in_(("open", "accepted", "modified")))).scalars()
    refs = [order_domain.RecommendationRef(r.id, r.type, r.product_id, r.suggested_quantity, r.status) for r in recs]
    channel = session.get(Channel, outlet.channel_id)
    promoted = {pid for _, pids in _active_promotions(session, principal.organization_id, channel.path, today) for pid in pids}
    suggestion = order_domain.suggest(outlet_id, lines, products, refs, promoted, today)
    return {"data_origin": principal.data_origin, "generator_version": order_domain.GENERATOR_VERSION,
            "lines": [asdict(s) for s in suggestion],
            "total_value": round(sum(s.quantity * s.unit_price for s in suggestion), 2),
            "note": "Suggestion only. The officer decides the final order; differences are tracked."}


class OrderLineIn(BaseModel):
    product_id: str
    quantity: int = Field(ge=1, le=100000)
    suggested_quantity: int | None = Field(default=None, ge=0)
    recommendation_id: str | None = None


class OrderIn(BaseModel):
    client_order_id: str = Field(min_length=8, max_length=64)
    visit_id: str | None = None
    lines: list[OrderLineIn] = Field(min_length=1)


@router.post("/outlets/{outlet_id}/orders", status_code=201)
def create_order(outlet_id: str, body: OrderIn, session: DB,
                 principal: Annotated[Principal, Depends(require("order:write"))]) -> dict:
    outlet = outlet_or_404(session, principal, outlet_id)
    ref = f"APP-{body.client_order_id}"
    existing = session.execute(select(Order).where(Order.organization_id == principal.organization_id,
                                                   Order.external_ref == ref)).scalar_one_or_none()
    if existing is not None:
        return {"id": existing.id, "status": existing.status, "replayed": True}
    products = loaders.load_products(session, principal.organization_id)
    order = Order(organization_id=principal.organization_id, data_origin=principal.data_origin, outlet_id=outlet.id,
                  user_id=principal.user_id, distributor_id=outlet.distributor_id, visit_id=body.visit_id,
                  order_date=date.today(), source="app", external_ref=ref, status="confirmed")
    for line in body.lines:
        product = products.get(line.product_id)
        if product is None or not product.is_own or not product.is_active:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"Product {line.product_id} cannot be ordered")
        if line.recommendation_id:
            rec = session.get(Recommendation, line.recommendation_id)
            if rec is None or rec.outlet_id != outlet.id:
                raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Recommendation does not belong to this outlet")
        if product.trade_price is None:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"No trade price configured for {product.sku}")
        price = product.trade_price
        order.items.append(OrderItem(organization_id=principal.organization_id, data_origin=principal.data_origin,
                                     product_id=product.id, quantity=line.quantity, unit_price=round(price, 2),
                                     line_value=round(price * line.quantity, 2),
                                     suggested_quantity=line.suggested_quantity, recommendation_id=line.recommendation_id))
    session.add(order)
    audit.record(session, principal, "order.create", "sales_order", None,
                 {"outlet_id": outlet.id, "lines": len(body.lines), "external_ref": ref})
    try:
        session.commit()
    except IntegrityError:
        session.rollback()
        existing = session.execute(select(Order).where(Order.organization_id == principal.organization_id,
                                                       Order.external_ref == ref)).scalar_one()
        return {"id": existing.id, "status": existing.status, "replayed": True}
    return {"id": order.id, "status": order.status, "replayed": False,
            "value": round(sum(float(i.line_value) for i in order.items), 2)}


# --- call preparation ------------------------------------------------------------------------


@router.get("/outlets/{outlet_id}/call-brief")
def call_brief(outlet_id: str, principal: Reader, session: DB) -> dict:
    outlet = outlet_or_404(session, principal, outlet_id)
    today = date.today()
    products = loaders.load_products(session, principal.organization_id, today)
    channel = session.get(Channel, outlet.channel_id)
    recent = session.execute(select(Order).where(Order.outlet_id == outlet_id).order_by(Order.order_date.desc()).limit(3)).scalars().all()
    last_orders = [{"id": o.id, "order_date": o.order_date.isoformat(), "lines": len(o.items),
                    "value": round(sum(float(i.line_value) for i in o.items), 2),
                    "products": [products[i.product_id].name for i in o.items if i.product_id in products][:6]} for o in recent]
    recs = session.execute(select(Recommendation).where(Recommendation.outlet_id == outlet_id, Recommendation.status == "open")).scalars().all()
    promos = [{"id": p.id, "name": p.name, "mechanic": p.mechanic, "ends_on": p.ends_on.isoformat(),
               "products": [products[pid].name for pid in pids if pid in products]}
              for p, pids in _active_promotions(session, principal.organization_id, channel.path, today)]
    manufacturers = dict(session.execute(select(Manufacturer.id, Manufacturer.name).where(Manufacturer.organization_id == principal.organization_id)).all())
    notes = [{"id": o.id, "source": o.source,
              "text": f"{manufacturers.get(o.manufacturer_id, 'Competitor')} {products[o.product_id].name if o.product_id in products else ''}"
                      f" seen at BDT {o.observed_price:g}" if o.observed_price else (o.notes or "")}
             for o in session.execute(select(CompetitorObservation).where(CompetitorObservation.outlet_id == outlet_id)
                                      .order_by(CompetitorObservation.observed_at.desc()).limit(3)).scalars()]
    classification = intelligence._current_classification(session, principal.organization_id, outlet_id)
    brief = call_prep.build(
        {"id": outlet.id, "name": outlet.name, "channel": channel.name}, classification, last_orders,
        [{"id": r.id, "action": r.action, "reason": r.reason, "priority": r.priority, "confidence": r.confidence,
          "source": r.source} for r in recs],
        promos, notes,
    )
    return {"data_origin": principal.data_origin, **asdict(brief)}


# --- classification override & observations -----------------------------------------------


class ClassificationOverrideIn(BaseModel):
    class_id: str
    note: str = Field(min_length=3, max_length=1000)


@router.post("/outlets/{outlet_id}/classification", status_code=201)
def override_classification(outlet_id: str, body: ClassificationOverrideIn, session: DB,
                            principal: Annotated[Principal, Depends(require("classification:override"))]) -> dict:
    outlet_or_404(session, principal, outlet_id)
    try:
        row = intelligence.override_classification(session, principal, outlet_id, body.class_id, body.note)
    except ValueError as exc:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(exc)) from exc
    session.commit()
    return {"id": row.id, "class_id": row.class_id, "source": row.source}


class ObservationIn(BaseModel):
    kind: str = Field(pattern="^(presence|price|promotion|display|note)$")
    manufacturer_id: str | None = None
    product_id: str | None = None
    observed_price: float | None = Field(default=None, gt=0)
    facings: int | None = Field(default=None, ge=0)
    notes: str | None = Field(default=None, max_length=1000)
    visit_id: str | None = None


@router.post("/outlets/{outlet_id}/competitor-observations", status_code=201)
def add_observation(outlet_id: str, body: ObservationIn, session: DB,
                    principal: Annotated[Principal, Depends(require("observation:write"))]) -> dict:
    outlet_or_404(session, principal, outlet_id)
    manufacturer_id = body.manufacturer_id
    brand_id = None
    if body.product_id:
        product = session.get(Product, body.product_id)
        if product is None or product.organization_id != principal.organization_id:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Unknown product")
        manufacturer_id, brand_id = product.manufacturer_id, product.brand_id
    if manufacturer_id is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "manufacturer_id or product_id is required")
    manufacturer = session.get(Manufacturer, manufacturer_id)
    if manufacturer is None or manufacturer.organization_id != principal.organization_id:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Unknown manufacturer")
    obs = CompetitorObservation(organization_id=principal.organization_id, data_origin=principal.data_origin,
                                outlet_id=outlet_id, visit_id=body.visit_id, user_id=principal.user_id,
                                manufacturer_id=manufacturer_id, brand_id=brand_id, product_id=body.product_id,
                                kind=body.kind, observed_price=body.observed_price, facings=body.facings,
                                notes=body.notes, source="manual")
    session.add(obs)
    session.commit()
    return {"id": obs.id}
