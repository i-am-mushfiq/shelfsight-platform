"""Explainable, configurable outlet classification.

A scheme is a list of classes in rank order; each class has criteria over named
features. The first class whose evaluable criteria all hold wins. The result
always carries the evidence (each criterion, the actual value, pass/fail) and a
confidence that reflects *data completeness*: the share of features the scheme
uses that were actually available for this outlet. A rule result is therefore
never more confident than the data behind it.
"""

from __future__ import annotations

import operator
from bisect import bisect_left
from dataclasses import dataclass

GENERATOR_VERSION = "classification-rules-1.0"

_OPS = {
    ">=": operator.ge, ">": operator.gt, "<=": operator.le, "<": operator.lt,
    "==": operator.eq, "!=": operator.ne,
}

FEATURES = {
    "monthly_sales_value": "Average monthly own-portfolio purchase value (BDT)",
    "sales_percentile_in_channel": "Percentile of monthly sales value among outlets in the same channel (0–1)",
    "distinct_skus": "Distinct own SKUs bought in the window",
    "distinct_categories": "Distinct categories bought in the window",
    "order_frequency_per_month": "Order days per month",
    "own_share_of_shelf": "Latest verified own share of shelf (0–1)",
    "shelf_meters": "Shelf length recorded for the outlet (m)",
    "size_sqft": "Outlet floor area (sq ft)",
}


@dataclass(frozen=True, slots=True)
class ClassSpec:
    id: str
    code: str
    label: str
    rank: int
    criteria: list[dict]


@dataclass(slots=True)
class ClassificationResult:
    class_id: str
    class_code: str
    class_label: str
    confidence: float
    evidence: dict


def percentile(value: float, population: list[float]) -> float:
    if not population:
        return 0.0
    ordered = sorted(population)
    return round(bisect_left(ordered, value) / len(ordered), 4)


def _check(criterion: dict, features: dict[str, float | None]) -> dict:
    feature = criterion["feature"]
    op = criterion["op"]
    expected = criterion["value"]
    actual = features.get(feature)
    if op not in _OPS:
        raise ValueError(f"Unsupported operator {op}")
    if actual is None:
        return {"feature": feature, "op": op, "value": expected, "actual": None, "result": "unknown"}
    passed = _OPS[op](actual, expected)
    return {"feature": feature, "op": op, "value": expected, "actual": actual,
            "result": "pass" if passed else "fail"}


def classify(classes: list[ClassSpec], features: dict[str, float | None]) -> ClassificationResult | None:
    if not classes:
        return None
    ordered = sorted(classes, key=lambda c: c.rank)
    used = {c["feature"] for cls in ordered for c in cls.criteria}
    available = {f for f in used if features.get(f) is not None}
    completeness = round(len(available) / len(used), 3) if used else 1.0
    trail = []
    for cls in ordered:
        checks = [_check(c, features) for c in cls.criteria]
        failed = [c for c in checks if c["result"] == "fail"]
        unknown = [c for c in checks if c["result"] == "unknown"]
        evaluable = [c for c in checks if c["result"] != "unknown"]
        matched = not failed and (evaluable or not checks)
        trail.append({"class": cls.code, "label": cls.label, "checks": checks,
                      "matched": bool(matched), "unknown_criteria": len(unknown)})
        if matched:
            reasons = [
                f"{FEATURES.get(c['feature'], c['feature'])}: {c['actual']} {c['op']} {c['value']}"
                for c in checks if c["result"] == "pass"
            ]
            # Matching a class with some unknown criteria lowers confidence further.
            confidence = completeness * (len(evaluable) / len(checks) if checks else 1.0)
            return ClassificationResult(
                class_id=cls.id, class_code=cls.code, class_label=cls.label,
                confidence=round(confidence, 3),
                evidence={
                    "features": features, "data_completeness": completeness, "reasons": reasons,
                    "evaluated": trail, "generator_version": GENERATOR_VERSION,
                },
            )
    return None
