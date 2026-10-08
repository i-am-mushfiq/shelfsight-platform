"""Suggested order: replenishment from history plus open/accepted recommendations.

Each line says where its quantity came from, so the officer can accept, edit or
drop it, and the platform can later compare suggestion → final order → sell-in.
"""

from __future__ import annotations

import math
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date, timedelta

from .records import OrderLine, ProductInfo

GENERATOR_VERSION = "order-suggestion-1.0"


@dataclass(frozen=True, slots=True)
class RecommendationRef:
    id: str
    type: str
    product_id: str | None
    suggested_quantity: int | None
    status: str


@dataclass(slots=True)
class SuggestedLine:
    product_id: str
    sku: str
    name: str
    quantity: int
    unit_price: float
    sources: list[dict] = field(default_factory=list)


def suggest(
    outlet_id: str,
    lines: list[OrderLine],
    products: dict[str, ProductInfo],
    recommendations: list[RecommendationRef],
    promoted_product_ids: set[str],
    as_of: date,
    window_days: int = 90,
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
            price = value[product.id] / units[product.id] if units.get(product.id) else (product.mrp or 0.0)
            suggestion[product.id] = SuggestedLine(product.id, product.sku, product.name, 0, round(price, 2))
        return suggestion[product.id]

    if order_days:
        for product_id, total in units.items():
            product = products.get(product_id)
            if product is None or not product.is_active:
                continue
            per_order = math.ceil(total / order_days)
            line = line_for(product)
            line.quantity += per_order
            line.sources.append({"source": "replenishment", "quantity": per_order,
                                 "evidence": {"units_in_window": total, "order_days": order_days,
                                              "window_days": window_days}})

    for rec in recommendations:
        if rec.status not in {"open", "accepted", "modified"} or not rec.product_id or not rec.suggested_quantity:
            continue
        if rec.type not in {"add_sku", "increase_volume"}:
            continue
        product = products.get(rec.product_id)
        if product is None or not product.is_active:
            continue
        line = line_for(product)
        line.quantity += rec.suggested_quantity
        line.sources.append({"source": "recommendation", "recommendation_id": rec.id,
                             "type": rec.type, "quantity": rec.suggested_quantity})

    for line in suggestion.values():
        if line.product_id in promoted_product_ids:
            line.sources.append({"source": "promotion", "note": "active promotion applies"})
    return sorted(suggestion.values(), key=lambda l: -l.quantity * l.unit_price)
