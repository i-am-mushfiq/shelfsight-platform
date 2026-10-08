"""Pre-call brief for a Sales Officer, grounded only in platform data.

Deterministic: every talking point is derived from a recommendation, an order
fact, a promotion or an observation, and cites it. An LLM may later rephrase or
translate the brief, but it must not add facts (see docs/architecture.md §5).
"""

from __future__ import annotations

from dataclasses import dataclass, field

GENERATOR_VERSION = "call-prep-1.0"


@dataclass(slots=True)
class TalkingPoint:
    kind: str  # opportunity | promotion | competitor | relationship | follow_up
    text: str
    citation: dict


@dataclass(slots=True)
class Brief:
    outlet: dict
    headline: str
    last_orders: list[dict]
    talking_points: list[TalkingPoint] = field(default_factory=list)
    generator_version: str = GENERATOR_VERSION


def build(
    outlet: dict,
    classification: dict | None,
    last_orders: list[dict],
    recommendations: list[dict],
    promotions: list[dict],
    competitor_notes: list[dict],
    max_points: int = 6,
) -> Brief:
    points: list[TalkingPoint] = []
    for rec in sorted(recommendations, key=lambda r: (r["priority"], -r["confidence"]))[:3]:
        points.append(TalkingPoint("opportunity", rec["action"] + " " + rec["reason"],
                                   {"recommendation_id": rec["id"], "source": rec["source"]}))
    for promo in promotions[:2]:
        names = ", ".join(promo.get("products", [])[:3])
        points.append(TalkingPoint("promotion", f"Active offer: {promo['name']} — {promo['mechanic']}" + (f" ({names})" if names else ""),
                                   {"promotion_id": promo["id"], "ends_on": promo["ends_on"]}))
    for note in competitor_notes[:1]:
        points.append(TalkingPoint("competitor", note["text"], {"observation_id": note.get("id"), "source": note.get("source")}))
    if last_orders:
        last = last_orders[0]
        points.append(TalkingPoint(
            "relationship",
            f"Last order {last['order_date']}: {last['lines']} lines, BDT {last['value']:,.0f}.",
            {"order_id": last["id"]},
        ))
    label = classification["label"] if classification else "unclassified"
    headline = f"{outlet['name']} · {outlet['channel']} · {label}"
    return Brief(outlet=outlet, headline=headline, last_orders=last_orders, talking_points=points[:max_points])
