"""Outlet intelligence dimensions. Each is kept separate; ``None`` means "not enough data".

Composite scores are deliberately not computed here; weighting is a business
decision that belongs in configuration once the dimensions have been validated.
"""

from __future__ import annotations

from dataclasses import dataclass

from .portfolio import PortfolioAnalysis
from .shelf import ShelfSummary
from .records import CoreItem

GENERATOR_VERSION = "scores-1.0"


@dataclass(slots=True)
class Score:
    dimension: str
    value: float | None
    unit: str
    inputs: dict


def assortment_score(analysis: PortfolioAnalysis, core: list[CoreItem]) -> Score:
    stats = {s.product_id: s for s in analysis.sku_stats}
    applicable = [c for c in core if c.product_id in stats]
    if not applicable:
        return Score("assortment", None, "pct", {"reason": "no core assortment configured for this outlet"})
    stocked = [c for c in applicable if stats[c.product_id].outlet_monthly_units > 0]
    return Score("assortment", round(100 * len(stocked) / len(applicable), 1), "pct", {
        "core_items": len(applicable), "ordered_in_window": len(stocked),
        "window_days": analysis.window["days"], "basis": "orders",
    })


def availability_score(summary: ShelfSummary | None, core: list[CoreItem]) -> Score:
    if summary is None:
        return Score("availability", None, "pct", {"reason": "no shelf audit yet"})
    if not summary.facings_by_product:
        return Score("availability", None, "pct", {
            "reason": "latest audit has no SKU-level identification", "basis": summary.basis,
        })
    if not core:
        return Score("availability", None, "pct", {"reason": "no core assortment configured"})
    seen = [c for c in core if summary.facings_by_product.get(c.product_id, 0) > 0]
    return Score("availability", round(100 * len(seen) / len(core), 1), "pct", {
        "core_items": len(core), "seen_on_shelf": len(seen), "basis": summary.basis,
    })


def share_of_shelf_score(summary: ShelfSummary | None, target: float | None) -> Score:
    if summary is None or summary.share_of_shelf is None:
        return Score("share_of_shelf", None, "pct", {"reason": "no shelf audit yet"})
    inputs = {
        "own_facings": summary.own_facings, "total_facings": summary.total_facings,
        "unknown_facings": summary.unknown_facings, "range": summary.share_of_shelf_range,
        "basis": summary.basis, "target": target,
    }
    if target:
        return Score("share_of_shelf", round(min(100.0, 100 * summary.share_of_shelf / target), 1), "pct_of_target", inputs)
    return Score("share_of_shelf", round(100 * summary.share_of_shelf, 1), "pct", inputs)


def placement_score(compliance: float | None, evaluated_rules: int) -> Score:
    if compliance is None:
        return Score("placement", None, "pct", {"reason": "no evaluable placement rules", "rules": evaluated_rules})
    return Score("placement", compliance, "pct", {"rules": evaluated_rules})


def competitor_pressure_score(summary: ShelfSummary | None) -> Score:
    if summary is None or not summary.total_facings:
        return Score("competitor_pressure", None, "pct", {"reason": "no shelf audit yet"})
    return Score("competitor_pressure", round(100 * summary.competitor_facings / summary.total_facings, 1), "pct", {
        "competitor_facings": summary.competitor_facings, "total_facings": summary.total_facings,
        "basis": summary.basis,
    })


def opportunity_score(analysis: PortfolioAnalysis) -> Score:
    gaps = [g for g in analysis.gaps if g.expected_monthly_value]
    value = round(sum(g.expected_monthly_value or 0 for g in gaps), 2)
    return Score("opportunity", value, "bdt_per_month", {
        "gaps_with_value": len(gaps),
        "note": "sum of peer-based expected monthly value of missing/under-indexed SKUs; not additive-certain",
    })
