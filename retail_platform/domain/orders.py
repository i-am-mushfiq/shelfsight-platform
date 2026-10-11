"""Suggested order: replenishment from history, shelf gaps from the latest photos, and
recommendations.

Each line says where its quantity came from, so the officer can accept, edit or drop it,
and the platform can later compare suggestion → final order → sell-in.

How the sources combine for one product:
  * history gives the usual order size (units per past order in the window);
  * the shelf gives the units needed to restore the facings the outlet should show
    (core assortment / placement target; at least one facing for anything it usually
    buys), but only for categories that were actually photographed;
  * the line takes the larger of the two — they are two estimates of the same need,
    so adding them would double count;
  * an "add SKU" recommendation raises the line to its quantity if that is larger; an
    "increase volume" recommendation adds on top (it is a gap beyond the usual order);
  * the result is rounded up to the product's order multiple.
"""

from __future__ import annotations

import math
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date, timedelta

from .records import OrderLine, ProductInfo, ShelfStock

GENERATOR_VERSION = "order-suggestion-2.0"
DEFAULT_UNITS_PER_FACING = 3
ALL_OPEN_STATUSES = frozenset({"open", "accepted", "modified"})


@dataclass(frozen=True, slots=True)
class RecommendationRef:
    id: str
    type: str
    product_id: str | None
    suggested_quantity: int | None
    status: str


@dataclass(frozen=True, slots=True)
class ShelfPolicy:
    """How a shelf gap becomes units: facings the outlet should show, and stock per facing."""

    units_per_facing: int = DEFAULT_UNITS_PER_FACING
    target_facings: dict[str, int] = field(default_factory=dict)


@dataclass(slots=True)
class SuggestedLine:
    product_id: str
    sku: str
    name: str
    quantity: int
    unit_price: float
    sources: list[dict] = field(default_factory=list)


def shelf_needs(products: dict[str, ProductInfo], shelf: ShelfStock, policy: ShelfPolicy,
                usual_buys: set[str]) -> dict[str, dict]:
    """Own products whose facings are below target on a photographed shelf, with the evidence."""
    needs: dict[str, dict] = {}
    candidates = set(policy.target_facings) | usual_buys | set(shelf.facings_by_product)
    for product_id in sorted(candidates):
        product = products.get(product_id)
        if product is None or not product.is_own or not product.is_active:
            continue
        if product.category_id not in shelf.covered_categories:
            continue  # this shelf was not photographed: no evidence either way
        target = policy.target_facings.get(product_id) or (1 if product_id in usual_buys else 0)
        seen = shelf.facings_by_product.get(product_id, 0)
        if not target or seen >= target:
            continue
        gap = target - seen
        unidentified = shelf.unidentified_by_category.get(product.category_id, 0)
        needs[product_id] = {
            "source": "shelf", "status": "missing" if seen == 0 else "low",
            "quantity": gap * policy.units_per_facing,
            # The missing facings may be among the boxes the model could not identify.
            "uncertain": unidentified >= gap,
            "evidence": {"facings_seen": seen, "target_facings": target, "units_per_facing": policy.units_per_facing,
                         "unidentified_facings_nearby": unidentified, "visit_id": shelf.visit_id,
                         "verified_ratio": shelf.verified_ratio},
        }
    return needs


def suggest(
    outlet_id: str,
    lines: list[OrderLine],
    products: dict[str, ProductInfo],
    recommendations: list[RecommendationRef],
    promoted_product_ids: set[str],
    as_of: date,
    window_days: int = 90,
    shelf: ShelfStock | None = None,
    policy: ShelfPolicy | None = None,
    recommendation_statuses: frozenset[str] = ALL_OPEN_STATUSES,
) -> list[SuggestedLine]:
    start = as_of - timedelta(days=window_days)
    history = [l for l in lines if l.outlet_id == outlet_id and start < l.order_date <= as_of]
    order_days = len({l.order_date for l in history})
    units: dict[str, int] = defaultdict(int)
    value: dict[str, float] = defaultdict(float)
    for line in history:
        units[line.product_id] += line.quantity
        value[line.product_id] += line.value

    suggestion: dict[str, SuggestedLine] = {}

    def line_for(product: ProductInfo) -> SuggestedLine:
        if product.id not in suggestion:
            historical = value[product.id] / units[product.id] if units.get(product.id) else None
            price = product.trade_price or historical or product.mrp or 0.0
            suggestion[product.id] = SuggestedLine(product.id, product.sku, product.name, 0, round(price, 2))
        return suggestion[product.id]

    replenishment: dict[str, dict] = {}
    if order_days:
        for product_id, total in units.items():
            product = products.get(product_id)
            if product is None or not product.is_active:
                continue
            per_order = math.ceil(total / order_days)
            replenishment[product_id] = {"source": "replenishment", "quantity": per_order,
                                         "evidence": {"units_in_window": total, "order_days": order_days,
                                                      "window_days": window_days}}

    needs = shelf_needs(products, shelf, policy or ShelfPolicy(), set(replenishment)) if shelf else {}
    for product_id in sorted(set(replenishment) | set(needs)):
        line = line_for(products[product_id])
        for source in (replenishment.get(product_id), needs.get(product_id)):
            if source:
                line.quantity = max(line.quantity, source["quantity"])
                line.sources.append(source)

    for rec in recommendations:
        if rec.status not in recommendation_statuses or not rec.product_id or not rec.suggested_quantity:
            continue
        if rec.type not in {"add_sku", "increase_volume"}:
            continue
        product = products.get(rec.product_id)
        if product is None or not product.is_active:
            continue
        line = line_for(product)
        line.quantity = line.quantity + rec.suggested_quantity if rec.type == "increase_volume" \
            else max(line.quantity, rec.suggested_quantity)
        line.sources.append({"source": "recommendation", "recommendation_id": rec.id,
                             "type": rec.type, "quantity": rec.suggested_quantity, "status": rec.status})

    for line in suggestion.values():
        multiple = products[line.product_id].order_multiple
        if multiple > 1 and line.quantity % multiple:
            line.quantity = math.ceil(line.quantity / multiple) * multiple
            line.sources.append({"source": "pack_multiple", "multiple": multiple})
        if line.product_id in promoted_product_ids:
            line.sources.append({"source": "promotion", "note": "active promotion applies"})
    return sorted((l for l in suggestion.values() if l.quantity > 0), key=lambda l: -l.quantity * l.unit_price)


def explain(source: dict) -> str:
    """One readable sentence for a line's source, for the app, the report and the order record."""
    kind = source.get("source")
    if kind == "replenishment":
        evidence = source.get("evidence", {})
        return (f"Usual order: {source['quantity']} (from {evidence.get('units_in_window')} units "
                f"over {evidence.get('order_days')} orders)")
    if kind == "shelf":
        evidence = source.get("evidence", {})
        state = "Missing on shelf" if source.get("status") == "missing" else "Low on shelf"
        text = (f"{state}: {evidence.get('facings_seen')} of {evidence.get('target_facings')} facings, "
                f"restock {source['quantity']}")
        if source.get("uncertain"):
            text += " (some facings could not be identified; check before sending)"
        return text
    if kind == "recommendation":
        action = "New product for this outlet" if source.get("type") == "add_sku" else "Grow volume"
        return f"{action}: {source['quantity']} ({source.get('status', 'open')} recommendation)"
    if kind == "pack_multiple":
        return f"Rounded up to packs of {source.get('multiple')}"
    if kind == "promotion":
        return "Active promotion applies"
    return str(kind)
