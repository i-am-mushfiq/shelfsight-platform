"""Visit report: everything one shop visit established, in one document.

Built on demand from stored rows (captures, detections, corrections, rules, orders), so it
always reflects the latest human review and can be regenerated months later. Figures state
their basis: "all" counts every detection, "verified" only human-reviewed ones.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import asdict
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..domain import availability, placement, portfolio, shelf
from ..models import (
    Brand,
    Category,
    Channel,
    Inference,
    Manufacturer,
    ModelVersion,
    Order,
    Outlet,
    Recommendation,
    ShelfCapture,
    User,
    Visit,
)
from ..vision import pipeline
from . import intelligence, loaders, ordering
from .intelligence import recommendation_out

# Use the verified basis for headline figures once this share of facings is reviewed.
VERIFIED_HEADLINE_RATIO = 0.8


def _channel(channel: Channel | None) -> dict | None:
    if channel is None:
        return None
    return {"id": channel.id, "code": channel.code, "name": channel.name, "name_bn": channel.name_bn,
            "icon": channel.icon}


def build_visit_report(session: Session, organization_id: str, visit: Visit) -> dict:
    outlet = session.get(Outlet, visit.outlet_id)
    assert outlet is not None
    products = loaders.load_products(session, organization_id)
    outlet_info = loaders.load_outlets(session, organization_id).get(outlet.id)
    officer = session.get(User, visit.user_id)
    store_type = session.get(Channel, visit.store_type_id or outlet.channel_id)
    previous = session.get(Channel, visit.previous_store_type_id) if visit.previous_store_type_id else None
    classification = intelligence._current_classification(session, organization_id, outlet.id)

    # --- photos ---------------------------------------------------------------------------
    captures = session.execute(select(ShelfCapture).where(ShelfCapture.visit_id == visit.id)
                               .order_by(ShelfCapture.uploaded_at)).scalars().all()
    latest = pipeline.latest_inference_ids(session, [c.id for c in captures])
    inferences = {i.id: i for i in session.execute(select(Inference).where(Inference.id.in_(latest.values()))).scalars()}
    versions = {v.id: v for v in session.execute(select(ModelVersion).where(
        ModelVersion.id.in_({i.model_version_id for i in inferences.values()}))).scalars()}
    category_names = dict(session.execute(select(Category.id, Category.name).where(
        Category.organization_id == organization_id)).all())
    warnings: list[str] = []
    for capture in captures:
        warnings += list(capture.quality.get("warnings", []))
        inference = inferences.get(latest.get(capture.id, ""))
        if inference:
            warnings += list(inference.warnings or [])
    models = sorted({(versions[i.model_version_id].provider, versions[i.model_version_id].version)
                     for i in inferences.values() if i.model_version_id in versions})
    photos = {
        "total": len(captures),
        "analysed": sum(c.status == "analysed" for c in captures),
        "failed": sum(c.status == "failed" for c in captures),
        "duplicates": sum(c.duplicate_of_id is not None for c in captures),
        "items": [{"id": c.id, "status": c.status, "category": category_names.get(c.category_id or ""),
                   "image_url": f"/v2/captures/{c.id}/image",
                   "annotated_url": f"/v2/inferences/{latest[c.id]}/annotated"
                   if c.id in latest and inferences[latest[c.id]].annotated_blob_key else None}
                  for c in captures],
        "models": [{"provider": p, "version": v} for p, v in models],
        "cost_usd": round(sum(i.cost_usd or 0 for i in inferences.values()), 6),
    }

    # --- shelf ----------------------------------------------------------------------------
    facings, model_versions = pipeline.visit_facings(session, visit.id)
    own = pipeline.own_manufacturer_ids(session, organization_id)
    summary_all = shelf.summarize(facings, own, "all")
    summary_verified = shelf.summarize(facings, own, "verified")
    headline = summary_verified if summary_all.total_facings and \
        summary_verified.total_facings and summary_all.verified_ratio >= VERIFIED_HEADLINE_RATIO else summary_all
    manufacturers = {m.id: m for m in session.execute(select(Manufacturer).where(
        Manufacturer.organization_id == organization_id)).scalars()}
    brands = {b.id: b for b in session.execute(select(Brand).where(Brand.organization_id == organization_id)).scalars()}
    live = [f for f in facings if f.label != "rejected" and (headline.basis == "all" or f.verified)]
    total = len(live)

    by_brand: dict[str, int] = defaultdict(int)
    by_category: dict[str, dict[str, int]] = defaultdict(lambda: {"own": 0, "competitor": 0, "unknown": 0})
    for facing in live:
        product = products.get(facing.product_id or "")
        if product:
            by_brand[product.brand_id] += 1
        side = facing.label if facing.label in {"own", "competitor"} else "unknown"
        by_category[facing.category_id or ""][side] += 1

    def share(count: int) -> float | None:
        return round(count / total, 4) if total else None

    shelf_section = {
        "basis": headline.basis,
        "all": asdict(summary_all), "verified": asdict(summary_verified),
        "share_of_shelf": headline.share_of_shelf, "range": headline.share_of_shelf_range,
        "total_facings": headline.total_facings, "own_facings": headline.own_facings,
        "competitor_facings": headline.competitor_facings, "unknown_facings": headline.unknown_facings,
        "verified_ratio": summary_all.verified_ratio, "model_versions": model_versions,
        "by_manufacturer": sorted(
            [{"id": mid, "name": manufacturers[mid].name if mid in manufacturers else mid,
              "is_own": manufacturers[mid].is_own if mid in manufacturers else False,
              "facings": count, "share": share(count)}
             for mid, count in headline.facings_by_manufacturer.items()],
            key=lambda row: -row["facings"]),
        "by_brand": sorted(
            [{"id": bid, "name": brands[bid].name, "manufacturer": manufacturers[brands[bid].manufacturer_id].name,
              "is_own": manufacturers[brands[bid].manufacturer_id].is_own, "facings": count, "share": share(count)}
             for bid, count in by_brand.items() if bid in brands],
            key=lambda row: -row["facings"]),
        "by_product": sorted(
            [{"id": pid, "sku": products[pid].sku, "name": products[pid].name, "brand": products[pid].brand_name,
              "manufacturer": products[pid].manufacturer_name, "is_own": products[pid].is_own,
              "category": products[pid].category_name, "facings": count, "share": share(count)}
             for pid, count in headline.facings_by_product.items() if pid in products],
            key=lambda row: (not row["is_own"], -row["facings"])),
        "by_category": sorted(
            [{"id": cid or None, "name": category_names.get(cid, "Mixed / not identified"), **counts,
              "total": sum(counts.values()),
              "own_share": round(counts["own"] / sum(counts.values()), 4) if sum(counts.values()) else None}
             for cid, counts in by_category.items()],
            key=lambda row: -row["total"]),
    }

    # --- availability, placement, recommendations, order ---------------------------------
    stock = ordering.shelf_stock(session, organization_id, visit.id)
    core, _ = loaders.load_core(session, organization_id)
    core_here = portfolio.applicable_core(core, outlet_info) if outlet_info else []
    available = availability.core_availability(core_here, products, stock)
    rules, rule_set = loaders.load_placement_rules(session, organization_id)
    placement_results = placement.evaluate(
        rules, facings, outlet_info.channel_path if outlet_info else "", {p.id: p.brand_id for p in products.values()},
        own, loaders.category_descendants(session, organization_id)) if facings else []
    recs = session.execute(select(Recommendation).where(
        Recommendation.visit_id == visit.id, Recommendation.status.in_(("open", "accepted", "modified")))
        .order_by(Recommendation.priority, Recommendation.confidence.desc())).scalars().all()
    # A cancelled automatic order is still shown, so the report says what happened to it.
    order = ordering.visit_order(session, visit) or session.execute(
        select(Order).where(Order.organization_id == organization_id, Order.external_ref == f"AUTO-{visit.id}")
    ).scalar_one_or_none()

    report = {
        "data_origin": visit.data_origin,
        "generated_at": datetime.now(UTC).isoformat(),
        "visit": {"id": visit.id, "status": visit.status, "started_at": visit.started_at.isoformat(),
                  "ended_at": visit.ended_at.isoformat() if visit.ended_at else None,
                  "distance_from_outlet_m": visit.distance_from_outlet_m,
                  "officer": {"id": officer.id, "name": officer.name, "employee_id": officer.employee_id} if officer else None},
        "outlet": {"id": outlet.id, "code": outlet.code, "name": outlet.name, "address": outlet.address,
                   "is_verified": outlet.is_verified,
                   "class": {"code": classification["code"], "label": classification["label"]} if classification else None},
        "store_type": _channel(store_type),
        "previous_store_type": _channel(previous),
        "photos": photos,
        "shelf": shelf_section,
        "availability": [{**asdict(a), "product": {"id": a.product_id, "sku": products[a.product_id].sku,
                                                  "name": products[a.product_id].name}} for a in available],
        "placement": {"score": placement.compliance_score(placement_results),
                      "rule_set": {"id": rule_set.id, "version": rule_set.version} if rule_set else None,
                      "results": [asdict(r) for r in placement_results]},
        "recommendations": [recommendation_out(r, products) for r in recs],
        "order": ordering.order_out(order, products) if order else None,
        "warnings": sorted(set(warnings)),
    }
    report["summary_text"] = summary_text(report)
    return report


def _pct(value: float | None) -> str:
    return "—" if value is None else f"{value * 100:.0f}%"


def summary_text(report: dict) -> str:
    """Plain-text report for messaging apps and email."""
    outlet, shelf_section, visit = report["outlet"], report["shelf"], report["visit"]
    lines = [f"ShelfSight visit report — {outlet['name']} ({outlet['code']})"]
    if report["data_origin"] == "synthetic":
        lines.append("SYNTHETIC DEMO DATA — not real sales or market figures")
    store = report["store_type"]["name"] if report["store_type"] else "unknown store type"
    if report["previous_store_type"]:
        store += f" (changed from {report['previous_store_type']['name']})"
    klass = f" · Class {outlet['class']['code']} {outlet['class']['label']}" if outlet["class"] else ""
    lines.append(f"Store type: {store}{klass}")
    officer = visit["officer"]["name"] if visit["officer"] else "unknown officer"
    lines.append(f"Visit: {visit['started_at'][:16].replace('T', ' ')} UTC by {officer} · "
                 f"{report['photos']['analysed']} of {report['photos']['total']} photos analysed")
    if shelf_section["total_facings"]:
        range_text = ""
        if shelf_section["range"] and shelf_section["range"][0] != shelf_section["range"][1]:
            range_text = f", could be {_pct(shelf_section['range'][0])}–{_pct(shelf_section['range'][1])}"
        lines.append(f"Own share of shelf: {_pct(shelf_section['share_of_shelf'])} of {shelf_section['total_facings']} "
                     f"facings ({shelf_section['basis']} basis, {_pct(shelf_section['verified_ratio'])} human-verified"
                     f"{range_text})")
        competitors = [m for m in shelf_section["by_manufacturer"] if not m["is_own"]][:4]
        if competitors:
            lines.append("Competitors: " + ", ".join(f"{m['name']} {_pct(m['share'])}" for m in competitors))
    else:
        lines.append("No product facings were detected.")
    for status, label in (("missing", "Missing on shelf"), ("low", "Low on shelf")):
        names = [a["product"]["name"] for a in report["availability"] if a["status"] == status]
        if names:
            lines.append(f"{label}: " + "; ".join(names))
    results = report["placement"]["results"]
    evaluable = [r for r in results if r["status"] != "not_evaluable"]
    if evaluable:
        lines.append(f"Placement: {sum(r['status'] == 'compliant' for r in evaluable)} of {len(evaluable)} rules met")
    order = report["order"]
    if order:
        lines.append(f"Order ({order['source']}, {order['status']}): {len(order['lines'])} lines · "
                     f"BDT {order['value']:,.0f}")
        for line in order["lines"]:
            reason = f" — {line['reasons'][0]}" if line["reasons"] else ""
            lines.append(f"  • {line['name']} × {line['quantity']}{reason}")
    else:
        lines.append("Order: none placed in this visit")
    for rec in report["recommendations"][:5]:
        lines.append(f"Action: {rec['action']}")
    return "\n".join(lines)
