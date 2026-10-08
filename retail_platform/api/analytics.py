"""Persona dashboards. Every endpoint is scoped to the outlets the caller may see."""

from __future__ import annotations

from collections import defaultdict
from datetime import UTC, date, datetime, timedelta
from statistics import median
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import get_settings
from ..models import (
    Brand,
    Channel,
    DetectedObject,
    Distributor,
    Inference,
    Manufacturer,
    ModelVersion,
    Order,
    OrderItem,
    Outlet,
    OutletAssignment,
    OutletScore,
    Recommendation,
    RecommendationFeedback,
    ShelfMeasurement,
    Territory,
    User,
    Visit,
)
from ..security import Principal, scoped_outlets
from ..services import loaders
from .deps import DB, require

router = APIRouter(prefix="/v2/analytics", tags=["analytics"])
Analyst = Annotated[Principal, Depends(require("analytics:read"))]

GROUPS = {"territory", "channel", "distributor", "officer", "outlet"}


def _scoped(session: Session, principal: Principal, territory: str | None, channel: str | None) -> list[Outlet]:
    query = scoped_outlets(session, principal).where(Outlet.is_active.is_(True))
    if territory:
        root = session.execute(select(Territory).where(Territory.organization_id == principal.organization_id,
                                                       Territory.code == territory)).scalar_one_or_none()
        if root is None:
            raise HTTPException(404, "Unknown territory")
        query = query.where(Outlet.territory_id.in_(select(Territory.id).where(Territory.path.startswith(root.path))))
    if channel:
        root_channel = session.execute(select(Channel).where(Channel.organization_id == principal.organization_id,
                                                             Channel.code == channel)).scalar_one_or_none()
        if root_channel is None:
            raise HTTPException(404, "Unknown channel")
        query = query.where(Outlet.channel_id.in_(select(Channel.id).where(Channel.path.startswith(root_channel.path))))
    return list(session.execute(query).scalars())


def _group_keys(session: Session, principal: Principal, outlets: list[Outlet], group_by: str) -> dict[str, tuple[str, str]]:
    """outlet_id -> (group id, group label)."""
    org = principal.organization_id
    if group_by == "territory":
        names = dict(session.execute(select(Territory.id, Territory.name).where(Territory.organization_id == org)).all())
        return {o.id: (o.territory_id, names.get(o.territory_id, "?")) for o in outlets}
    if group_by == "channel":
        names = dict(session.execute(select(Channel.id, Channel.name).where(Channel.organization_id == org)).all())
        return {o.id: (o.channel_id, names.get(o.channel_id, "?")) for o in outlets}
    if group_by == "distributor":
        names = dict(session.execute(select(Distributor.id, Distributor.name).where(Distributor.organization_id == org)).all())
        return {o.id: (o.distributor_id or "none", names.get(o.distributor_id, "Unassigned")) for o in outlets}
    if group_by == "officer":
        today = date.today()
        rows = session.execute(
            select(OutletAssignment.outlet_id, User.id, User.name).join(User, User.id == OutletAssignment.user_id)
            .where(OutletAssignment.organization_id == org, OutletAssignment.effective_from <= today,
                   (OutletAssignment.effective_to.is_(None)) | (OutletAssignment.effective_to >= today))).all()
        mapping = {outlet_id: (user_id, name) for outlet_id, user_id, name in rows}
        return {o.id: mapping.get(o.id, ("none", "Unassigned")) for o in outlets}
    return {o.id: (o.id, o.name) for o in outlets}


def _latest_scores(session: Session, outlet_ids: list[str]) -> dict[str, dict[str, float | None]]:
    rows = session.execute(select(OutletScore.outlet_id, OutletScore.dimension, OutletScore.value, OutletScore.computed_at)
                           .where(OutletScore.outlet_id.in_(outlet_ids)).order_by(OutletScore.computed_at))
    latest: dict[str, dict[str, float | None]] = defaultdict(dict)
    for outlet_id, dimension, value, _ in rows:
        latest[outlet_id][dimension] = value
    return latest


def _latest_shelf(session: Session, outlet_ids: list[str], basis: str) -> dict[str, dict]:
    """Latest visit's own share of shelf per outlet."""
    rows = session.execute(select(ShelfMeasurement).where(ShelfMeasurement.outlet_id.in_(outlet_ids),
                                                          ShelfMeasurement.metric == "share_of_shelf",
                                                          ShelfMeasurement.basis == basis)
                           .order_by(ShelfMeasurement.computed_at)).scalars()
    by_outlet: dict[str, dict] = {}
    visit_of: dict[str, str] = {}
    for m in rows:
        if visit_of.get(m.outlet_id) != m.visit_id:
            visit_of[m.outlet_id] = m.visit_id
            by_outlet[m.outlet_id] = {"visit_id": m.visit_id, "total": m.denominator, "own": None, "manufacturers": {}}
        entry = by_outlet[m.outlet_id]
        if m.scope_type == "own":
            entry["own"] = m.numerator
        elif m.scope_type == "manufacturer" and m.scope_id:
            entry["manufacturers"][m.scope_id] = m.numerator
    return by_outlet


@router.get("/overview")
def overview(principal: Analyst, session: DB, group_by: str = Query("territory"),
             territory: str | None = None, channel: str | None = None, window_days: int = Query(90, ge=7, le=365)) -> dict:
    if group_by not in GROUPS:
        raise HTTPException(422, f"group_by must be one of {sorted(GROUPS)}")
    outlets = _scoped(session, principal, territory, channel)
    ids = [o.id for o in outlets]
    keys = _group_keys(session, principal, outlets, group_by)
    since = date.today() - timedelta(days=window_days)
    months = window_days / 30.44
    value: dict[str, float] = defaultdict(float)
    for outlet_id, line_value in session.execute(
        select(Order.outlet_id, OrderItem.line_value).join(OrderItem, OrderItem.order_id == Order.id)
        .where(Order.outlet_id.in_(ids), Order.order_date > since, Order.status == "confirmed")):
        value[outlet_id] += float(line_value)
    scores = _latest_scores(session, ids)
    shelf = _latest_shelf(session, ids, "all")
    visited_since = datetime.now(UTC) - timedelta(days=30)
    visited = set(session.execute(select(Visit.outlet_id).where(Visit.outlet_id.in_(ids), Visit.started_at >= visited_since)).scalars())
    open_recs: dict[str, list[Recommendation]] = defaultdict(list)
    for rec in session.execute(select(Recommendation).where(Recommendation.outlet_id.in_(ids), Recommendation.status == "open")).scalars():
        open_recs[rec.outlet_id].append(rec)

    groups: dict[str, dict] = {}
    for outlet in outlets:
        group_id, label = keys[outlet.id]
        g = groups.setdefault(group_id, {"id": group_id, "label": label, "outlets": 0, "monthly_value_bdt": 0.0,
                                         "visited_30d": 0, "audited": 0, "own_facings": 0.0, "total_facings": 0.0,
                                         "open_recommendations": 0, "opportunity_bdt_per_month": 0.0,
                                         "_scores": defaultdict(list)})
        g["outlets"] += 1
        g["monthly_value_bdt"] += value[outlet.id] / months
        g["visited_30d"] += outlet.id in visited
        if outlet.id in shelf and shelf[outlet.id]["own"] is not None:
            g["audited"] += 1
            g["own_facings"] += shelf[outlet.id]["own"]
            g["total_facings"] += shelf[outlet.id]["total"]
        g["open_recommendations"] += len(open_recs[outlet.id])
        for dimension, score in scores.get(outlet.id, {}).items():
            if score is not None:
                g["_scores"][dimension].append(score)
    rows = []
    for g in groups.values():
        dims = g.pop("_scores")
        opportunity = dims.pop("opportunity", [])
        g["opportunity_bdt_per_month"] = round(sum(opportunity), 2)
        g["scores"] = {d: {"mean": round(sum(v) / len(v), 1), "outlets_scored": len(v)} for d, v in dims.items()}
        g["share_of_shelf"] = round(g["own_facings"] / g["total_facings"], 4) if g["total_facings"] else None
        g["monthly_value_bdt"] = round(g["monthly_value_bdt"], 2)
        g["coverage_30d"] = round(g["visited_30d"] / g["outlets"], 3) if g["outlets"] else 0.0
        rows.append(g)
    rows.sort(key=lambda r: -r["monthly_value_bdt"])
    return {"data_origin": principal.data_origin, "group_by": group_by, "window_days": window_days,
            "notes": {"share_of_shelf": "facings-weighted, latest audit per outlet, all detections (see /competition for basis)",
                      "scores": "mean of latest per-outlet dimension scores; outlets without data are excluded, not zeroed"},
            "groups": rows}


@router.get("/brands")
def brand_distribution(principal: Analyst, session: DB, territory: str | None = None, channel: str | None = None,
                       window_days: int = Query(90, ge=7, le=365)) -> dict:
    """Own-portfolio performance: value, value share and numeric distribution by brand and SKU."""
    outlets = _scoped(session, principal, territory, channel)
    ids = [o.id for o in outlets]
    products = loaders.load_products(session, principal.organization_id)
    since = date.today() - timedelta(days=window_days)
    brand_value: dict[str, float] = defaultdict(float)
    brand_outlets: dict[str, set[str]] = defaultdict(set)
    sku_outlets: dict[str, set[str]] = defaultdict(set)
    sku_value: dict[str, float] = defaultdict(float)
    for outlet_id, product_id, line_value in session.execute(
        select(Order.outlet_id, OrderItem.product_id, OrderItem.line_value).join(OrderItem, OrderItem.order_id == Order.id)
        .where(Order.outlet_id.in_(ids), Order.order_date > since, Order.status == "confirmed")):
        product = products.get(product_id)
        if product is None:
            continue
        brand_value[product.brand_id] += float(line_value)
        brand_outlets[product.brand_id].add(outlet_id)
        sku_outlets[product_id].add(outlet_id)
        sku_value[product_id] += float(line_value)
    total = sum(brand_value.values())
    brand_names = dict(session.execute(select(Brand.id, Brand.name).where(Brand.organization_id == principal.organization_id)).all())
    return {
        "data_origin": principal.data_origin, "outlets_in_scope": len(ids), "window_days": window_days,
        "basis": "own-brand secondary sales; numeric distribution = share of in-scope outlets that bought in window",
        "brands": sorted([{"brand_id": b, "brand": brand_names.get(b, b), "value_bdt": round(v, 2),
                           "value_share": round(v / total, 4) if total else 0.0,
                           "numeric_distribution": round(len(brand_outlets[b]) / len(ids), 4) if ids else 0.0}
                          for b, v in brand_value.items()], key=lambda r: -r["value_bdt"]),
        "skus": sorted([{"product_id": p, "sku": products[p].sku, "name": products[p].name,
                         "value_bdt": round(sku_value[p], 2),
                         "numeric_distribution": round(len(sku_outlets[p]) / len(ids), 4) if ids else 0.0}
                        for p in sku_outlets], key=lambda r: -r["numeric_distribution"]),
    }


@router.get("/competition")
def competition(principal: Analyst, session: DB, group_by: str = Query("channel"), basis: str = Query("all", pattern="^(all|verified)$"),
                territory: str | None = None, channel: str | None = None) -> dict:
    """Share of shelf by manufacturer from each outlet's latest audit (facings-weighted)."""
    if group_by not in GROUPS:
        raise HTTPException(422, f"group_by must be one of {sorted(GROUPS)}")
    outlets = _scoped(session, principal, territory, channel)
    ids = [o.id for o in outlets]
    keys = _group_keys(session, principal, outlets, group_by)
    shelf = _latest_shelf(session, ids, basis)
    manufacturers = {m.id: m for m in session.execute(select(Manufacturer).where(Manufacturer.organization_id == principal.organization_id)).scalars()}
    groups: dict[str, dict] = {}
    for outlet_id, entry in shelf.items():
        group_id, label = keys[outlet_id]
        g = groups.setdefault(group_id, {"id": group_id, "label": label, "outlets_audited": 0, "total_facings": 0.0,
                                         "own_facings": 0.0, "_by": defaultdict(float)})
        g["outlets_audited"] += 1
        g["total_facings"] += entry["total"]
        g["own_facings"] += entry["own"] or 0
        for manufacturer_id, facings in entry["manufacturers"].items():
            g["_by"][manufacturer_id] += facings
    rows = []
    for g in groups.values():
        by = g.pop("_by")
        identified = sum(by.values())
        g["share_of_shelf_own"] = round(g["own_facings"] / g["total_facings"], 4) if g["total_facings"] else None
        g["unidentified_share"] = round(1 - identified / g["total_facings"], 4) if g["total_facings"] else None
        g["manufacturers"] = sorted([{"id": mid, "name": manufacturers[mid].name if mid in manufacturers else mid,
                                      "is_own": manufacturers[mid].is_own if mid in manufacturers else False,
                                      "facings": f, "share_of_shelf": round(f / g["total_facings"], 4)}
                                     for mid, f in by.items()], key=lambda r: -r["facings"])
        rows.append(g)
    return {"data_origin": principal.data_origin, "basis": basis, "group_by": group_by,
            "outlets_in_scope": len(ids), "outlets_audited": len(shelf),
            "caveat": "Competitor shares are only as good as recognition; 'unidentified_share' is facings with no manufacturer.",
            "groups": sorted(rows, key=lambda r: -r["total_facings"])}


@router.get("/recommendations")
def recommendation_funnel(principal: Analyst, session: DB, territory: str | None = None, channel: str | None = None,
                          conversion_days: int = Query(30, ge=1, le=120)) -> dict:
    """Closed loop: generated → accepted/modified/rejected → ordered within N days."""
    outlets = _scoped(session, principal, territory, channel)
    ids = [o.id for o in outlets]
    recs = session.execute(select(Recommendation).where(Recommendation.outlet_id.in_(ids))).scalars().all()
    orders = session.execute(select(Order.outlet_id, Order.order_date, OrderItem.product_id, OrderItem.recommendation_id)
                             .join(OrderItem, OrderItem.order_id == Order.id)
                             .where(Order.outlet_id.in_(ids), Order.status == "confirmed")).all()
    ordered_after: dict[tuple[str, str], list[date]] = defaultdict(list)
    linked = {rec_id for *_, rec_id in orders if rec_id}
    for outlet_id, order_date, product_id, _ in orders:
        ordered_after[(outlet_id, product_id)].append(order_date)
    by_type: dict[str, dict] = defaultdict(lambda: defaultdict(int))
    for rec in recs:
        stats = by_type[rec.type]
        stats["generated"] += 1
        stats[rec.status] += 1
        if rec.status in {"accepted", "modified"} and rec.product_id:
            created = rec.created_at.date()
            if rec.id in linked or any(created <= d <= created + timedelta(days=conversion_days)
                                       for d in ordered_after.get((rec.outlet_id, rec.product_id), [])):
                stats["ordered"] += 1
    feedback_count = len(session.execute(select(RecommendationFeedback.id).where(
        RecommendationFeedback.recommendation_id.in_([r.id for r in recs]))).all()) if recs else 0
    return {"data_origin": principal.data_origin, "conversion_days": conversion_days, "feedback_events": feedback_count,
            "by_type": {t: dict(v) for t, v in by_type.items()},
            "note": "Ordered = linked order line, or same product ordered by the outlet within the window. Correlation, not causation."}


@router.get("/ai")
def ai_quality(principal: Annotated[Principal, Depends(require("team:read"))], session: DB) -> dict:
    """Per model version: volume, latency, cost, review load, and correction-based confusion."""
    org = principal.organization_id
    versions = {v.id: v for v in session.execute(select(ModelVersion).where(ModelVersion.organization_id == org)).scalars()}
    inferences = session.execute(select(Inference).where(Inference.organization_id == org)).scalars().all()
    detections = session.execute(select(DetectedObject.inference_id, DetectedObject.predicted_label, DetectedObject.final_label,
                                        DetectedObject.verification, DetectedObject.needs_review, DetectedObject.confidence,
                                        DetectedObject.predicted_product_id, DetectedObject.final_product_id)
                                 .where(DetectedObject.organization_id == org)).all()
    version_of = {i.id: i.model_version_id for i in inferences}
    threshold = get_settings().review_confidence_threshold
    report: dict[str, dict] = {}
    for version_id, version in versions.items():
        runs = [i for i in inferences if i.model_version_id == version_id]
        latencies = sorted(i.latency_ms for i in runs if i.latency_ms is not None)
        dets = [d for d in detections if version_of.get(d[0]) == version_id]
        reviewed = [d for d in dets if d[3] != "unverified"]
        confusion: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
        for d in reviewed:
            confusion[d[1]]["rejected" if d[3] == "rejected" else d[2]] += 1
        sku_reviewed = [d for d in reviewed if d[6] and d[3] != "rejected"]
        report[version_id] = {
            "version": version.version, "provider": version.provider, "status": version.status,
            "inferences": len(runs), "failed": sum(i.status == "failed" for i in runs),
            "latency_ms": {"p50": median(latencies) if latencies else None,
                           "p95": latencies[int(0.95 * (len(latencies) - 1))] if latencies else None},
            "cost_usd": round(sum(i.cost_usd or 0 for i in runs), 4),
            # Recomputed from the prediction: needs_review is cleared once a human has reviewed.
            "detections": len(dets),
            "flagged_for_review": sum(d[1] == "unknown" or d[5] < threshold for d in dets),
            "reviewed": len(reviewed),
            "label_accuracy_on_reviewed": round(sum(d[1] == d[2] and d[3] != "rejected" for d in reviewed) / len(reviewed), 4) if reviewed else None,
            "sku_accuracy_on_reviewed": round(sum(d[6] == d[7] for d in sku_reviewed) / len(sku_reviewed), 4) if sku_reviewed else None,
            "confusion_predicted_to_final": {k: dict(v) for k, v in confusion.items()},
        }
    return {"data_origin": principal.data_origin, "models": report,
            "caveat": "Accuracy here is measured only on human-reviewed detections, which are biased toward low-confidence cases. "
                      "Release decisions use the frozen holdout evaluation, not this view."}
