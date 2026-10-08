"""Read models: database rows → domain dataclasses. Always tenant-filtered."""

from __future__ import annotations

from collections import defaultdict
from datetime import date

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from ..domain.placement import RuleSpec
from ..domain.records import CoreItem, OrderLine, OutletInfo, ProductInfo, Target
from ..models import (
    Brand,
    Category,
    Channel,
    ClassScheme,
    CoreAssortmentItem,
    Manufacturer,
    Order,
    OrderItem,
    Outlet,
    OutletClass,
    OutletClassification,
    PlacementRule,
    PortfolioTarget,
    Product,
    ProductPrice,
    RuleSet,
)


def load_products(session: Session, organization_id: str, as_of: date | None = None) -> dict[str, ProductInfo]:
    as_of = as_of or date.today()
    current: dict[str, dict[str, float]] = {"mrp": {}, "trade": {}}
    prices = session.execute(
        select(ProductPrice.product_id, ProductPrice.price_type, ProductPrice.amount, ProductPrice.effective_from)
        .where(ProductPrice.organization_id == organization_id, ProductPrice.price_type.in_(("mrp", "trade")),
               ProductPrice.effective_from <= as_of,
               or_(ProductPrice.effective_to.is_(None), ProductPrice.effective_to >= as_of))
        .order_by(ProductPrice.effective_from)
    )
    for product_id, price_type, amount, _ in prices:
        current[price_type][product_id] = float(amount)
    mrp, trade = current["mrp"], current["trade"]
    rows = session.execute(
        select(Product, Brand.name, Manufacturer.name, Manufacturer.is_own, Category.name)
        .join(Brand, Product.brand_id == Brand.id)
        .join(Manufacturer, Product.manufacturer_id == Manufacturer.id)
        .join(Category, Product.category_id == Category.id)
        .where(Product.organization_id == organization_id)
    )
    return {
        product.id: ProductInfo(
            id=product.id, sku=product.sku, name=product.name, brand_id=product.brand_id, brand_name=brand,
            manufacturer_id=product.manufacturer_id, manufacturer_name=manufacturer, is_own=is_own,
            category_id=product.category_id, category_name=category, price_tier=product.price_tier,
            pack_size=product.pack_size, pack_unit=product.pack_unit, mrp=mrp.get(product.id),
            trade_price=trade.get(product.id),
            is_active=product.is_active and (product.discontinued_on is None or product.discontinued_on > as_of),
        )
        for product, brand, manufacturer, is_own, category in rows
    }


def active_scheme(session: Session, organization_id: str) -> ClassScheme | None:
    return session.execute(
        select(ClassScheme).where(ClassScheme.organization_id == organization_id, ClassScheme.status == "active")
        .order_by(ClassScheme.version.desc()).limit(1)
    ).scalar_one_or_none()


def effective_classifications(session: Session, organization_id: str, scheme_id: str | None) -> dict[str, OutletClassification]:
    """Latest human assessment wins; otherwise the latest rule/model assessment."""
    if scheme_id is None:
        return {}
    rows = session.execute(
        select(OutletClassification).where(OutletClassification.organization_id == organization_id,
                                           OutletClassification.scheme_id == scheme_id)
        .order_by(OutletClassification.assessed_at)
    ).scalars()
    human: dict[str, OutletClassification] = {}
    automatic: dict[str, OutletClassification] = {}
    for row in rows:
        (human if row.source == "human" else automatic)[row.outlet_id] = row
    return {**automatic, **human}


def load_outlets(session: Session, organization_id: str) -> dict[str, OutletInfo]:
    scheme = active_scheme(session, organization_id)
    classes = effective_classifications(session, organization_id, scheme.id if scheme else None)
    labels = dict(session.execute(
        select(OutletClass.id, OutletClass.label).where(OutletClass.organization_id == organization_id)
    ).all())
    rows = session.execute(
        select(Outlet, Channel.path).join(Channel, Outlet.channel_id == Channel.id)
        .where(Outlet.organization_id == organization_id, Outlet.is_active.is_(True))
    )
    result = {}
    for outlet, channel_path in rows:
        assessment = classes.get(outlet.id)
        result[outlet.id] = OutletInfo(
            id=outlet.id, code=outlet.code, name=outlet.name, channel_id=outlet.channel_id,
            channel_path=channel_path, territory_id=outlet.territory_id,
            class_id=assessment.class_id if assessment else None,
            class_label=labels.get(assessment.class_id) if assessment else None,
            shelf_meters=outlet.shelf_meters, size_sqft=outlet.size_sqft,
        )
    return result


def load_order_lines(session: Session, organization_id: str, since: date) -> list[OrderLine]:
    rows = session.execute(
        select(Order.outlet_id, OrderItem.product_id, Order.order_date, OrderItem.quantity, OrderItem.line_value)
        .join(OrderItem, OrderItem.order_id == Order.id)
        .where(Order.organization_id == organization_id, Order.order_date > since, Order.status == "confirmed")
    )
    return [OrderLine(o, p, d, int(q), float(v)) for o, p, d, q, v in rows]


def active_rule_set(session: Session, organization_id: str, kind: str) -> RuleSet | None:
    return session.execute(
        select(RuleSet).where(RuleSet.organization_id == organization_id, RuleSet.kind == kind,
                              RuleSet.status == "active").order_by(RuleSet.version.desc()).limit(1)
    ).scalar_one_or_none()


def load_targets(session: Session, organization_id: str) -> tuple[list[Target], RuleSet | None]:
    rule_set = active_rule_set(session, organization_id, "portfolio")
    if rule_set is None:
        return [], None
    rows = session.execute(select(PortfolioTarget).where(PortfolioTarget.rule_set_id == rule_set.id)).scalars()
    return [Target(r.id, r.channel_id, r.outlet_class_id, r.category_id, r.dimension, r.dimension_value,
                   r.target_share, r.tolerance) for r in rows], rule_set


def load_core(session: Session, organization_id: str) -> tuple[list[CoreItem], RuleSet | None]:
    rule_set = active_rule_set(session, organization_id, "assortment")
    if rule_set is None:
        return [], None
    rows = session.execute(select(CoreAssortmentItem).where(CoreAssortmentItem.rule_set_id == rule_set.id)).scalars()
    return [CoreItem(r.id, r.channel_id, r.outlet_class_id, r.product_id, r.min_facings, r.priority) for r in rows], rule_set


def load_placement_rules(session: Session, organization_id: str) -> tuple[list[RuleSpec], RuleSet | None]:
    rule_set = active_rule_set(session, organization_id, "placement")
    if rule_set is None:
        return [], None
    paths = dict(session.execute(select(Channel.id, Channel.path).where(Channel.organization_id == organization_id)).all())
    rows = session.execute(select(PlacementRule).where(PlacementRule.rule_set_id == rule_set.id)).scalars()
    return [RuleSpec(
        id=r.id, channel_id=r.channel_id, channel_path=paths.get(r.channel_id) if r.channel_id else None,
        category_id=r.category_id, product_id=r.product_id, brand_id=r.brand_id, manufacturer_id=r.manufacturer_id,
        preferred_band=r.preferred_band, min_facings=r.min_facings, min_share_of_shelf=r.min_share_of_shelf,
        priority=r.priority, promo_required=r.promo_required, description=r.description,
    ) for r in rows], rule_set


def category_descendants(session: Session, organization_id: str) -> dict[str, set[str]]:
    rows = session.execute(select(Category.id, Category.path).where(Category.organization_id == organization_id)).all()
    result: dict[str, set[str]] = defaultdict(set)
    for category_id, path in rows:
        for other_id, other_path in rows:
            if other_path.startswith(path):
                result[category_id].add(other_id)
    return result
