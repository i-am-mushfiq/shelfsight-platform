"""Orders from the database: what a visit's photos show, the outlet's shelf targets, the
suggested order, and the automatic order a submitted visit produces.

The automatic order only contains what evidence supports — usual order sizes, shelf gaps
on photographed shelves, and recommendations the officer accepted. Open (unreviewed)
recommendations stay suggestions on the order screen; they never reach an order on
their own.
"""

from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import asdict, dataclass
from datetime import UTC, date, datetime, timedelta

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from .. import audit
from ..domain import orders as order_domain
from ..domain import portfolio
from ..domain.records import OutletInfo, ProductInfo, ShelfStock
from ..models import (
    Channel,
    Order,
    OrderItem,
    Outlet,
    Promotion,
    PromotionProduct,
    Recommendation,
    ShelfCapture,
    Visit,
)
from ..security import Principal
from ..vision import pipeline
from . import loaders

# Photos older than this say little about today's shelf.
SHELF_EVIDENCE_MAX_AGE_DAYS = 7
# App and auto orders can be changed or cancelled for this long after they were created.
EDIT_WINDOW_HOURS = 24
HISTORY_DAYS = 120
AUTO_ORDER_RECOMMENDATIONS = frozenset({"accepted", "modified"})


def shelf_stock(session: Session, organization_id: str, visit_id: str) -> ShelfStock | None:
    """Shelf evidence from one visit, or None when none of its photos has been analysed.

    A photo only says a product is absent when products on it were identified at SKU level
    (by the model or by the officer). A logo-only model sees "Square" but not which Square
    product, so its photos never mark anything as missing.
    """
    captures = session.execute(
        select(ShelfCapture).where(ShelfCapture.visit_id == visit_id, ShelfCapture.duplicate_of_id.is_(None),
                                   ShelfCapture.status == "analysed")
    ).scalars().all()
    if not captures:
        return None
    facings, versions = pipeline.visit_facings(session, visit_id)
    descendants = loaders.category_descendants(session, organization_id)
    live = [f for f in facings if f.label != "rejected"]
    identified_photos = {f.capture_id for f in live if f.product_id}
    covered: set[str] = set()
    for capture in captures:
        if capture.category_id and capture.id in identified_photos:
            covered |= descendants.get(capture.category_id, {capture.category_id})
    for facing in live:
        if facing.product_id and facing.category_id:
            covered.add(facing.category_id)
    unidentified: dict[str, int] = defaultdict(int)
    for facing in live:
        if facing.product_id or facing.label == "competitor":
            continue
        # Without a product, a facing's category is its photo's category (None for a mixed rack,
        # where it could belong to any photographed category).
        scope = descendants.get(facing.category_id, {facing.category_id}) if facing.category_id else covered
        for category_id in scope:
            unidentified[category_id] += 1
    reviewed = sum(f.verified for f in live)
    return ShelfStock(
        visit_id=visit_id, covered_categories=frozenset(covered),
        facings_by_product=dict(Counter(f.product_id for f in live if f.product_id)),
        unidentified_by_category=dict(unidentified),
        verified_ratio=round(reviewed / len(live), 4) if live else 0.0, model_versions=tuple(versions),
    )


def latest_shelf_visit(session: Session, outlet_id: str, as_of: date | None = None) -> Visit | None:
    since = datetime.combine((as_of or date.today()) - timedelta(days=SHELF_EVIDENCE_MAX_AGE_DAYS),
                             datetime.min.time(), tzinfo=UTC)
    analysed = select(ShelfCapture.visit_id).where(ShelfCapture.outlet_id == outlet_id,
                                                   ShelfCapture.status == "analysed")
    return session.execute(
        select(Visit).where(Visit.outlet_id == outlet_id, Visit.started_at >= since, Visit.id.in_(analysed))
        .order_by(Visit.started_at.desc()).limit(1)
    ).scalar_one_or_none()


def units_per_facing(session: Session, channel_id: str) -> int:
    """The channel's restock depth, inherited from its parents; the domain default otherwise."""
    channel = session.get(Channel, channel_id)
    while channel is not None:
        if channel.units_per_facing:
            return channel.units_per_facing
        channel = session.get(Channel, channel.parent_id) if channel.parent_id else None
    return order_domain.DEFAULT_UNITS_PER_FACING


def shelf_policy(session: Session, organization_id: str, outlet: OutletInfo) -> order_domain.ShelfPolicy:
    """Facings the outlet should show: core assortment minimums and product-level placement rules."""
    core, _ = loaders.load_core(session, organization_id)
    targets = {item.product_id: item.min_facings for item in portfolio.applicable_core(core, outlet)}
    rules, _ = loaders.load_placement_rules(session, organization_id)
    for rule in rules:
        if rule.product_id and (not rule.channel_path or outlet.channel_path.startswith(rule.channel_path)):
            targets[rule.product_id] = max(targets.get(rule.product_id, 0), rule.min_facings)
    return order_domain.ShelfPolicy(units_per_facing(session, outlet.channel_id), targets)


def active_promotions(session: Session, organization_id: str, channel_path: str,
                      today: date) -> list[tuple[Promotion, list[str]]]:
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


@dataclass(slots=True)
class OrderSuggestion:
    outlet: OutletInfo
    lines: list[order_domain.SuggestedLine]
    products: dict[str, ProductInfo]
    shelf: ShelfStock | None
    policy: order_domain.ShelfPolicy


def build_suggestion(session: Session, organization_id: str, outlet_id: str, *, visit_id: str | None = None,
                     as_of: date | None = None,
                     recommendation_statuses: frozenset[str] = order_domain.ALL_OPEN_STATUSES) -> OrderSuggestion:
    """``visit_id`` names the visit whose photos to use; without it, the latest recent audit is used."""
    today = as_of or date.today()
    products = loaders.load_products(session, organization_id, today)
    outlet = loaders.load_outlets(session, organization_id)[outlet_id]
    lines = loaders.load_order_lines(session, organization_id, today - timedelta(days=HISTORY_DAYS))
    recs = session.execute(select(Recommendation).where(Recommendation.outlet_id == outlet_id,
                                                        Recommendation.status.in_(recommendation_statuses))).scalars()
    refs = [order_domain.RecommendationRef(r.id, r.type, r.product_id, r.suggested_quantity, r.status) for r in recs]
    promoted = {pid for _, pids in active_promotions(session, organization_id, outlet.channel_path, today) for pid in pids}
    if visit_id is None:
        latest = latest_shelf_visit(session, outlet_id, today)
        visit_id = latest.id if latest else None
    stock = shelf_stock(session, organization_id, visit_id) if visit_id else None
    policy = shelf_policy(session, organization_id, outlet)
    suggestion = order_domain.suggest(outlet_id, lines, products, refs, promoted, today, shelf=stock, policy=policy,
                                      recommendation_statuses=recommendation_statuses)
    return OrderSuggestion(outlet, suggestion, products, stock, policy)


def suggestion_out(suggestion: OrderSuggestion, data_origin: str) -> dict:
    shelf = suggestion.shelf
    return {
        "data_origin": data_origin, "generator_version": order_domain.GENERATOR_VERSION,
        "lines": [{**asdict(line), "reasons": [order_domain.explain(s) for s in line.sources]}
                  for line in suggestion.lines],
        "total_value": round(sum(line.quantity * line.unit_price for line in suggestion.lines), 2),
        "shelf_evidence": {"visit_id": shelf.visit_id, "categories_photographed": len(shelf.covered_categories),
                           "verified_ratio": shelf.verified_ratio} if shelf else None,
        "units_per_facing": suggestion.policy.units_per_facing,
        "note": "Suggestion only. The officer decides the final order; differences are tracked.",
    }


def visit_order(session: Session, visit: Visit) -> Order | None:
    """The order placed in this visit: the automatic one, or one the officer placed by hand."""
    return session.execute(
        select(Order).where(Order.organization_id == visit.organization_id,
                            or_(Order.external_ref == f"AUTO-{visit.id}", Order.visit_id == visit.id),
                            Order.status != "cancelled")
        .order_by(Order.created_at).limit(1)
    ).scalar_one_or_none()


def create_auto_order(session: Session, principal: Principal, visit: Visit, mode: str) -> Order | None:
    """Create the visit's order from its shelf evidence. Idempotent; None when nothing to order."""
    if mode == "off":
        return None
    existing = visit_order(session, visit)
    if existing is not None or session.execute(
        select(Order.id).where(Order.organization_id == visit.organization_id, Order.external_ref == f"AUTO-{visit.id}")
    ).first():
        return existing
    suggestion = build_suggestion(session, visit.organization_id, visit.outlet_id, visit_id=visit.id,
                                  recommendation_statuses=AUTO_ORDER_RECOMMENDATIONS)
    priced = [l for l in suggestion.lines if suggestion.products[l.product_id].trade_price is not None]
    unpriced = [suggestion.products[l.product_id].sku for l in suggestion.lines if l not in priced]
    if not priced:
        return None
    outlet = session.get(Outlet, visit.outlet_id)
    assert outlet is not None
    order = Order(
        organization_id=visit.organization_id, data_origin=visit.data_origin, outlet_id=visit.outlet_id,
        user_id=visit.user_id, distributor_id=outlet.distributor_id, visit_id=visit.id, order_date=date.today(),
        source="auto", external_ref=f"AUTO-{visit.id}", status="confirmed" if mode == "confirm" else "draft",
        meta={"generator_version": order_domain.GENERATOR_VERSION, "mode": mode,
              "shelf_visit_id": suggestion.shelf.visit_id if suggestion.shelf else None,
              "units_per_facing": suggestion.policy.units_per_facing, "skipped_without_trade_price": unpriced},
    )
    for line in priced:
        price = float(suggestion.products[line.product_id].trade_price or 0)
        recommendation_id = next((s["recommendation_id"] for s in line.sources if s["source"] == "recommendation"), None)
        order.items.append(OrderItem(
            organization_id=visit.organization_id, data_origin=visit.data_origin, product_id=line.product_id,
            quantity=line.quantity, unit_price=round(price, 2), line_value=round(price * line.quantity, 2),
            suggested_quantity=line.quantity, recommendation_id=recommendation_id, sources=line.sources,
        ))
    session.add(order)
    session.flush()
    audit.record(session, principal, "order.auto_create", "sales_order", order.id,
                 {"visit_id": visit.id, "status": order.status, "lines": len(order.items),
                  "value": round(sum(float(i.line_value) for i in order.items), 2)})
    return order


def editable(order: Order, now: datetime | None = None) -> bool:
    if order.source not in {"app", "auto"} or order.status not in {"draft", "confirmed"}:
        return False
    created = order.created_at if order.created_at.tzinfo else order.created_at.replace(tzinfo=UTC)
    return (now or datetime.now(UTC)) - created <= timedelta(hours=EDIT_WINDOW_HOURS)


def order_out(order: Order, products: dict[str, ProductInfo]) -> dict:
    def line(item: OrderItem) -> dict:
        product = products.get(item.product_id)
        sources = item.sources or []
        return {
            "id": item.id, "product_id": item.product_id, "sku": product.sku if product else None,
            "name": product.name if product else item.product_id, "brand": product.brand_name if product else None,
            "quantity": item.quantity, "unit_price": float(item.unit_price), "line_value": float(item.line_value),
            "suggested_quantity": item.suggested_quantity, "recommendation_id": item.recommendation_id,
            "sources": sources, "reasons": [order_domain.explain(s) for s in sources],
        }

    return {
        "id": order.id, "outlet_id": order.outlet_id, "visit_id": order.visit_id, "user_id": order.user_id,
        "source": order.source, "status": order.status, "external_ref": order.external_ref,
        "order_date": order.order_date.isoformat(), "created_at": order.created_at.isoformat(),
        "value": round(sum(float(i.line_value) for i in order.items), 2), "lines": [line(i) for i in order.items],
        "meta": order.meta or {}, "editable": editable(order), "data_origin": order.data_origin,
    }
