"""Recommendation generators. Every recommendation carries reason, evidence, confidence,
priority and source; none is presented as fact.

Generators are pure: they turn analysis results into drafts. Persistence, dedupe and
feedback handling live in services.recommendations.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

from .competitor import ManufacturerPresence
from .placement import RuleResult
from .portfolio import PortfolioAnalysis
from .shelf import ShelfSummary
from .records import ProductInfo

GENERATOR_VERSION = "recommendations-1.0"


@dataclass(slots=True)
class Draft:
    type: str
    action: str
    reason: str
    evidence: dict
    confidence: float
    priority: int
    source: str
    dedupe_key: str
    product_id: str | None = None
    suggested_quantity: int | None = None
    expected_impact: dict = field(default_factory=dict)


def _qty(units: float | None) -> int | None:
    """Nearest whole unit (min 1). Rounding up would systematically over-suggest."""
    if not units or units <= 0:
        return None
    return max(1, math.floor(units + 0.5))


def from_portfolio(outlet_id: str, analysis: PortfolioAnalysis, products: dict[str, ProductInfo]) -> list[Draft]:
    drafts: list[Draft] = []
    for gap in analysis.gaps:
        product = products.get(gap.product_id or "")
        impact = {}
        if gap.expected_monthly_units:
            impact["monthly_units"] = gap.expected_monthly_units
        if gap.expected_monthly_value:
            impact["monthly_value_bdt"] = gap.expected_monthly_value
        impact["basis"] = "peer benchmark (associative, not causal)"
        evidence = {**gap.evidence, "gap_kind": gap.kind, "analysis_window": analysis.window,
                    "portfolio_generator": analysis.generator_version}
        if gap.kind == "missing_core" and product:
            drafts.append(Draft(
                type="add_sku", product_id=product.id,
                action=f"Add {product.name} ({product.sku}) — core assortment item.",
                reason=gap.message, evidence=evidence, confidence=gap.confidence,
                priority=gap.priority, source="portfolio.core_assortment",
                dedupe_key=f"{outlet_id}:add_sku:{product.id}",
                suggested_quantity=_qty(gap.expected_monthly_units) or 1, expected_impact=impact,
            ))
        elif gap.kind == "missing_vs_peers" and product:
            drafts.append(Draft(
                type="add_sku", product_id=product.id,
                action=f"Introduce {product.name} ({product.sku}).",
                reason=gap.message, evidence=evidence, confidence=gap.confidence,
                priority=gap.priority, source="portfolio.peer_benchmark",
                dedupe_key=f"{outlet_id}:add_sku:{product.id}",
                suggested_quantity=_qty(gap.expected_monthly_units), expected_impact=impact,
            ))
        elif gap.kind == "under_indexed" and product:
            drafts.append(Draft(
                type="increase_volume", product_id=product.id,
                action=f"Grow {product.name} by about {_qty(gap.expected_monthly_units)} units/month.",
                reason=gap.message, evidence=evidence, confidence=gap.confidence,
                priority=gap.priority, source="portfolio.peer_benchmark",
                dedupe_key=f"{outlet_id}:increase_volume:{product.id}",
                suggested_quantity=_qty(gap.expected_monthly_units), expected_impact=impact,
            ))
        elif gap.kind == "mix_under_target":
            drafts.append(Draft(
                type="rebalance_mix",
                action=f"Push {gap.dimension} '{_label(gap, analysis)}' — below target share.",
                reason=gap.message, evidence=evidence, confidence=gap.confidence,
                priority=gap.priority, source="portfolio.target_mix",
                dedupe_key=f"{outlet_id}:rebalance_mix:{gap.dimension}:{gap.dimension_value}",
                expected_impact={"basis": "configured target"},
            ))
    return drafts


def _label(gap, analysis: PortfolioAnalysis) -> str:  # type: ignore[no-untyped-def]
    for entry in analysis.target_mix.get(gap.dimension or "", []):
        if entry["key"] == gap.dimension_value:
            return entry["label"]
    return gap.dimension_value or ""


def from_placement(
    outlet_id: str, visit_id: str | None, results: list[RuleResult], model_versions: list[str]
) -> list[Draft]:
    drafts: list[Draft] = []
    for result in results:
        if result.status != "non_compliant":
            continue
        failures = "; ".join(result.observed.get("failures", []))
        unknown = result.observed.get("unknown_facings_in_scope", 0)
        # Unidentified facings make a failure less certain: they might be the expected product.
        scope = max(1, result.observed.get("scope_facings", 1))
        confidence = round(0.85 * (1 - unknown / scope), 3)
        short = result.observed.get("facings", 0) < result.expected.get("min_facings", 0)
        drafts.append(Draft(
            type="increase_facings" if short else "fix_placement",
            action=f"{result.description}: {failures}.",
            reason=f"Channel placement rule not met — {failures}.",
            evidence={"rule_id": result.rule_id, "observed": result.observed, "expected": result.expected,
                      "detection_ids": result.detection_ids[:50], "visit_id": visit_id,
                      "model_versions": model_versions},
            confidence=confidence, priority=result.priority, source="placement.rules",
            dedupe_key=f"{outlet_id}:placement:{result.rule_id}",
            expected_impact={"basis": "compliance"},
        ))
    return drafts


def from_competition(
    outlet_id: str,
    visit_id: str | None,
    summary: ShelfSummary | None,
    presence: list[ManufacturerPresence],
    own_share_target: float | None,
) -> list[Draft]:
    if summary is None or not summary.total_facings or own_share_target is None:
        return []
    own_share = summary.share_of_shelf or 0.0
    upper = summary.share_of_shelf_range[1] if summary.share_of_shelf_range else own_share
    if upper >= own_share_target:
        return []  # even the optimistic reading meets target: no claim to make
    leader = next((p for p in presence if not p.is_own and p.facings > 0), None)
    leader_text = f"; largest competitor {leader.name} holds {leader.share_of_shelf:.0%}" if leader and leader.share_of_shelf else ""
    return [Draft(
        type="competitor_response",
        action=f"Negotiate more shelf space: own share {own_share:.0%} vs target {own_share_target:.0%}{leader_text}.",
        reason=(
            f"Own share of shelf is {own_share:.0%} (up to {upper:.0%} if every unidentified facing were own), "
            f"below the {own_share_target:.0%} target."
        ),
        evidence={"share_of_shelf": own_share, "range": summary.share_of_shelf_range,
                  "own_facings": summary.own_facings, "total_facings": summary.total_facings,
                  "unknown_facings": summary.unknown_facings, "basis": summary.basis,
                  "competitors": [{"name": p.name, "facings": p.facings, "share": p.share_of_shelf}
                                  for p in presence if not p.is_own][:5],
                  "visit_id": visit_id},
        confidence=round(0.9 * summary.verified_ratio + 0.4 * (1 - summary.verified_ratio), 3),
        priority=2, source="competitor.share_of_shelf",
        dedupe_key=f"{outlet_id}:competitor_response:share_of_shelf",
        expected_impact={"share_gap": round(own_share_target - own_share, 4)},
    )]
