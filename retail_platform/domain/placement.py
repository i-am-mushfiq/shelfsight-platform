"""Channel-wise placement compliance.

Rules are data (models.rules.PlacementRule). This module evaluates them against
detected facings and is the single consumer used by analytics, recommendations
and the field app, so a rule means the same thing everywhere.

Each rule yields one of:
  compliant       expectation met
  non_compliant   expectation not met, with what was observed
  not_evaluable   the evidence cannot answer the rule (e.g. product-level rule but
                  the model only knows own vs competitor) — never guessed
"""

from __future__ import annotations

from dataclasses import dataclass

from .shelf import band_for
from .records import Facing

GENERATOR_VERSION = "placement-1.0"


@dataclass(frozen=True, slots=True)
class RuleSpec:
    id: str
    channel_id: str | None
    channel_path: str | None  # rule applies to this channel and its descendants
    category_id: str | None
    product_id: str | None
    brand_id: str | None
    manufacturer_id: str | None
    preferred_band: str
    min_facings: int
    min_share_of_shelf: float | None
    priority: int
    promo_required: bool
    description: str


@dataclass(slots=True)
class RuleResult:
    rule_id: str
    status: str
    description: str
    priority: int
    observed: dict
    expected: dict
    detection_ids: list[str]


def _in_category(category_id: str | None, rule_category: str | None, descendants: dict[str, set[str]]) -> bool:
    if rule_category is None:
        return True
    if category_id is None:
        return False
    return category_id in descendants.get(rule_category, {rule_category})


def rule_applies(
    rule: RuleSpec,
    outlet_channel_path: str,
    capture_categories: set[str | None],
    descendants: dict[str, set[str]] | None = None,
) -> bool:
    if rule.channel_path and not outlet_channel_path.startswith(rule.channel_path):
        return False
    if rule.category_id is None:
        return True
    descendants = descendants or {}
    for category in capture_categories:
        # The capture is inside the rule's category, or it covers a broader shelf that
        # contains the rule's category (e.g. photo tagged "Skin Cleansing", rule on "Bar Soap").
        if _in_category(category, rule.category_id, descendants) or (
            category is not None and rule.category_id in descendants.get(category, set())
        ):
            return True
    return False


def evaluate(
    rules: list[RuleSpec],
    facings: list[Facing],
    outlet_channel_path: str,
    brand_of_product: dict[str, str],
    own_manufacturers: set[str],
    descendants: dict[str, set[str]] | None = None,
) -> list[RuleResult]:
    """``descendants`` maps a category to itself plus its sub-categories, so a rule on
    "Skin Cleansing" also covers facings recognised as "Bar Soap"."""
    descendants = descendants or {}
    live = [f for f in facings if f.label != "rejected"]
    categories = {f.category_id for f in live}
    results: list[RuleResult] = []
    for rule in rules:
        if not rule_applies(rule, outlet_channel_path, categories, descendants):
            continue
        scope = [f for f in live if _in_category(f.category_id, rule.category_id, descendants)]
        expected = {
            "preferred_band": rule.preferred_band, "min_facings": rule.min_facings,
            "min_share_of_shelf": rule.min_share_of_shelf,
        }
        if not scope:
            results.append(RuleResult(rule.id, "not_evaluable", rule.description, rule.priority,
                                      {"reason": "no facing was identified in this rule's category "
                                                 "(needs SKU-level recognition or a more specific shelf selection)"},
                                      expected, []))
            continue

        if rule.product_id or rule.brand_id:
            identified = [f for f in scope if f.product_id]
            if not identified:
                results.append(RuleResult(
                    rule.id, "not_evaluable", rule.description, rule.priority,
                    {"reason": "detections are not identified at SKU/brand level"}, expected, [],
                ))
                continue
            if rule.product_id:
                matches = [f for f in identified if f.product_id == rule.product_id]
            else:
                matches = [f for f in identified if brand_of_product.get(f.product_id or "") == rule.brand_id]
        elif rule.manufacturer_id:
            matches = [f for f in scope if f.manufacturer_id == rule.manufacturer_id]
        else:
            matches = [f for f in scope if f.label == "own" or f.manufacturer_id in own_manufacturers]

        bands = {band_for(f.shelf_row, f.shelf_rows_total) for f in matches}
        in_band = [f for f in matches if rule.preferred_band == "any" or band_for(f.shelf_row, f.shelf_rows_total) == rule.preferred_band]
        share = len(matches) / len(scope) if scope else 0.0
        failures: list[str] = []
        if len(matches) < rule.min_facings:
            failures.append(f"{len(matches)} facings, expected at least {rule.min_facings}")
        if rule.preferred_band != "any" and matches and not in_band:
            failures.append(f"not at {rule.preferred_band} level (seen at: {', '.join(sorted(b or 'unknown' for b in bands))})")
        if rule.min_share_of_shelf is not None and share < rule.min_share_of_shelf:
            failures.append(f"share of shelf {share:.0%}, expected at least {rule.min_share_of_shelf:.0%}")
        unknown = sum(f.label == "unknown" for f in scope)
        observed = {
            "facings": len(matches), "facings_in_preferred_band": len(in_band),
            "bands_seen": sorted(b or "unknown" for b in bands), "share_of_shelf": round(share, 4),
            "scope_facings": len(scope), "unknown_facings_in_scope": unknown,
            "failures": failures,
        }
        status = "compliant" if not failures else "non_compliant"
        results.append(RuleResult(rule.id, status, rule.description, rule.priority, observed,
                                  expected, [f.id for f in matches]))
    return results


def compliance_score(results: list[RuleResult]) -> float | None:
    """Priority-weighted share of evaluable rules that are compliant (priority 1 weighs 3×)."""
    evaluable = [r for r in results if r.status != "not_evaluable"]
    if not evaluable:
        return None
    weight = {1: 3.0, 2: 2.0, 3: 1.0}
    total = sum(weight.get(r.priority, 1.0) for r in evaluable)
    passed = sum(weight.get(r.priority, 1.0) for r in evaluable if r.status == "compliant")
    return round(100 * passed / total, 1)
