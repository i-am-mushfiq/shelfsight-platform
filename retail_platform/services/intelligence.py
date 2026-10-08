"""Outlet intelligence orchestration: loads data, runs the domain engines, persists outputs.

Persisted outputs (scores, classifications, recommendations) record generator and
rule-set versions so any figure can be traced back six months later.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import UTC, date, datetime, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import audit
from ..domain import classification, competitor, placement, portfolio, recommendations, scoring, shelf
from ..domain.records import OutletInfo, ProductInfo
from ..models import (
    CompetitorObservation,
    Manufacturer,
    OutletClass,
    OutletClassification,
    OutletScore,
    Recommendation,
    ShelfMeasurement,
    Visit,
)
from ..security import Principal
from ..vision.pipeline import own_manufacturer_ids, visit_facings
from . import loaders

LOOKBACK_DAYS = 400  # enough history for the longest configured window plus seasonality checks


@dataclass(slots=True)
class OutletIntelligence:
    outlet: OutletInfo
    as_of: date
    portfolio: portfolio.PortfolioAnalysis
    classification: dict | None
    latest_visit: dict | None
    shelf: dict | None
    placement: list[dict]
    placement_score: float | None
    competitors: list[dict]
    price_positioning: list[dict]
    scores: list[scoring.Score]
    drafts: list[recommendations.Draft]
    rule_sets: dict


def _latest_analysed_visit(session: Session, outlet_id: str) -> Visit | None:
    visits = session.execute(
        select(Visit).where(Visit.outlet_id == outlet_id).order_by(Visit.started_at.desc()).limit(10)
    ).scalars()
    for visit in visits:
        has_measurement = session.execute(
            select(ShelfMeasurement.id).where(ShelfMeasurement.visit_id == visit.id).limit(1)
        ).first()
        if has_measurement:
            return visit
    return None


def _own_share_target(rules: list[placement.RuleSpec], outlet: OutletInfo) -> float | None:
    targets = [r.min_share_of_shelf for r in rules
               if r.min_share_of_shelf is not None and not r.product_id and not r.brand_id
               and (not r.channel_path or outlet.channel_path.startswith(r.channel_path))]
    return max(targets) if targets else None


def analyze(session: Session, organization_id: str, outlet_id: str, as_of: date | None = None) -> OutletIntelligence:
    as_of = as_of or date.today()
    products = loaders.load_products(session, organization_id, as_of)
    outlets = loaders.load_outlets(session, organization_id)
    if outlet_id not in outlets:
        raise KeyError(outlet_id)
    outlet = outlets[outlet_id]
    lines = loaders.load_order_lines(session, organization_id, as_of - timedelta(days=LOOKBACK_DAYS))
    targets, portfolio_rules = loaders.load_targets(session, organization_id)
    core, assortment_rules = loaders.load_core(session, organization_id)
    rules, placement_rules = loaders.load_placement_rules(session, organization_id)
    analysis = portfolio.analyze_outlet(outlet, outlets, products, lines, targets, core, as_of)
    core_here = portfolio.applicable_core(core, outlet)

    # --- shelf evidence from the latest analysed visit ---------------------------------------
    visit = _latest_analysed_visit(session, outlet_id)
    summary_all = summary_verified = None
    placement_results: list[placement.RuleResult] = []
    presence: list[competitor.ManufacturerPresence] = []
    model_versions: list[str] = []
    own = own_manufacturer_ids(session, organization_id)
    manufacturers = {m.id: (m.name, m.is_own) for m in session.execute(
        select(Manufacturer).where(Manufacturer.organization_id == organization_id)).scalars()}
    if visit is not None:
        facings, model_versions = visit_facings(session, visit.id)
        summary_all = shelf.summarize(facings, own, "all")
        summary_verified = shelf.summarize(facings, own, "verified")
        brand_of = {p.id: p.brand_id for p in products.values()}
        descendants = loaders.category_descendants(session, organization_id)
        placement_results = placement.evaluate(rules, facings, outlet.channel_path, brand_of, own, descendants)
        observed = competitor.summary_to_observations(outlet_id, summary_all, products)
        presence = competitor.presence_by_manufacturer(observed, manufacturers)

    manual = session.execute(
        select(CompetitorObservation).where(CompetitorObservation.outlet_id == outlet_id)
        .order_by(CompetitorObservation.observed_at.desc()).limit(50)
    ).scalars().all()
    manual_obs = [competitor.ObservedProduct(outlet_id, o.product_id, o.manufacturer_id,
                                             products[o.product_id].category_id if o.product_id in products else None,
                                             o.facings or 0, o.observed_price, o.source) for o in manual]
    prices = competitor.price_positioning(manual_obs, products)

    # Prefer the verified basis for scoring once most facings are reviewed; otherwise use all.
    summary = summary_verified if summary_verified and summary_verified.verified_ratio >= 0.8 else summary_all
    compliance = placement.compliance_score(placement_results)
    own_target = _own_share_target(rules, outlet)
    scores = [
        scoring.assortment_score(analysis, core_here),
        scoring.availability_score(summary, core_here),
        scoring.share_of_shelf_score(summary, own_target),
        scoring.placement_score(compliance, len([r for r in placement_results if r.status != "not_evaluable"])),
        scoring.competitor_pressure_score(summary),
        scoring.opportunity_score(analysis),
    ]
    drafts = recommendations.from_portfolio(outlet_id, analysis, products)
    if visit is not None:
        drafts += recommendations.from_placement(outlet_id, visit.id, placement_results, model_versions)
        drafts += recommendations.from_competition(outlet_id, visit.id, summary, presence, own_target)

    classification_row = _current_classification(session, organization_id, outlet_id)
    return OutletIntelligence(
        outlet=outlet, as_of=as_of, portfolio=analysis, classification=classification_row,
        latest_visit={"id": visit.id, "started_at": visit.started_at.isoformat(), "model_versions": model_versions} if visit else None,
        shelf={"all": asdict(summary_all) if summary_all else None,
               "verified": asdict(summary_verified) if summary_verified else None} if visit else None,
        placement=[asdict(r) for r in placement_results], placement_score=compliance,
        competitors=[asdict(p) for p in presence], price_positioning=prices,
        scores=scores, drafts=drafts,
        rule_sets={k: ({"id": v.id, "version": v.version, "name": v.name} if v else None)
                   for k, v in (("portfolio", portfolio_rules), ("assortment", assortment_rules), ("placement", placement_rules))},
    )


def _current_classification(session: Session, organization_id: str, outlet_id: str) -> dict | None:
    scheme = loaders.active_scheme(session, organization_id)
    if scheme is None:
        return None
    rows = session.execute(
        select(OutletClassification).where(OutletClassification.outlet_id == outlet_id,
                                           OutletClassification.scheme_id == scheme.id)
        .order_by(OutletClassification.assessed_at)
    ).scalars().all()
    if not rows:
        return None
    human = [r for r in rows if r.source == "human"]
    current = (human or rows)[-1]
    latest_auto = next((r for r in reversed(rows) if r.source != "human"), None)
    cls = session.get(OutletClass, current.class_id)
    return {
        "scheme": {"id": scheme.id, "code": scheme.code, "version": scheme.version, "name": scheme.name},
        "class_id": current.class_id, "code": cls.code if cls else None, "label": cls.label if cls else None,
        "source": current.source, "confidence": current.confidence, "evidence": current.evidence,
        "assessed_at": current.assessed_at.isoformat(),
        "system_assessment": {
            "class_id": latest_auto.class_id, "confidence": latest_auto.confidence,
            "source": latest_auto.source,
        } if latest_auto and latest_auto is not current else None,
    }


def persist(session: Session, organization_id: str, intel: OutletIntelligence, data_origin: str,
            visit_id: str | None = None) -> list[Recommendation]:
    for score in intel.scores:
        session.add(OutletScore(organization_id=organization_id, data_origin=data_origin,
                                outlet_id=intel.outlet.id, dimension=score.dimension, value=score.value,
                                inputs={**score.inputs, "unit": score.unit, "as_of": intel.as_of.isoformat(),
                                        "rule_sets": intel.rule_sets},
                                generator_version=scoring.GENERATOR_VERSION))
    sources = {"portfolio.core_assortment", "portfolio.peer_benchmark", "portfolio.target_mix"}
    if intel.latest_visit:
        sources |= {"placement.rules", "competitor.share_of_shelf"}
    return sync_recommendations(session, organization_id, intel.outlet.id, intel.drafts, sources, data_origin,
                                intel.rule_sets, visit_id)


REJECTION_COOLDOWN_DAYS = 30


def sync_recommendations(session: Session, organization_id: str, outlet_id: str,
                         drafts: list[recommendations.Draft], sources_run: set[str], data_origin: str,
                         rule_sets: dict, visit_id: str | None = None) -> list[Recommendation]:
    """Upsert open recommendations by dedupe key; supersede stale ones from the sources that ran.

    Accepted/modified/rejected recommendations are history and are never rewritten. A
    recommendation rejected recently is not re-raised until the cooldown passes.
    """
    existing = session.execute(
        select(Recommendation).where(Recommendation.outlet_id == outlet_id)
    ).scalars().all()
    open_by_key = {r.dedupe_key: r for r in existing if r.status == "open"}
    cooldown_from = datetime.now(UTC) - timedelta(days=REJECTION_COOLDOWN_DAYS)
    recently_rejected = {
        r.dedupe_key for r in existing
        if r.status == "rejected" and _aware(r.updated_at) >= cooldown_from
    }
    seen: set[str] = set()
    result: list[Recommendation] = []
    for draft in drafts:
        seen.add(draft.dedupe_key)
        if draft.dedupe_key in recently_rejected:
            continue
        evidence = {**draft.evidence, "rule_sets": rule_sets}
        rec = open_by_key.get(draft.dedupe_key)
        if rec is None:
            rec = Recommendation(organization_id=organization_id, data_origin=data_origin, outlet_id=outlet_id,
                                 dedupe_key=draft.dedupe_key, type=draft.type, status="open")
            session.add(rec)
        rec.visit_id = visit_id or rec.visit_id
        rec.product_id = draft.product_id
        rec.action, rec.reason, rec.evidence = draft.action, draft.reason, evidence
        rec.expected_impact, rec.suggested_quantity = draft.expected_impact, draft.suggested_quantity
        rec.confidence, rec.priority, rec.source = draft.confidence, draft.priority, draft.source
        rec.generator_version = recommendations.GENERATOR_VERSION
        result.append(rec)
    for key, rec in open_by_key.items():
        if key not in seen and rec.source in sources_run:
            rec.status = "superseded"
    session.flush()
    return sorted(result, key=lambda r: (r.priority, -r.confidence))


def _aware(value: datetime) -> datetime:
    return value if value.tzinfo else value.replace(tzinfo=UTC)


# --- classification ------------------------------------------------------------------------


def outlet_features(session: Session, organization_id: str, as_of: date, window_days: int = 90) -> dict[str, dict[str, float | None]]:
    outlets = loaders.load_outlets(session, organization_id)
    products = loaders.load_products(session, organization_id, as_of)
    lines = loaders.load_order_lines(session, organization_id, as_of - timedelta(days=window_days))
    months = window_days / portfolio.DAYS_PER_MONTH
    value: dict[str, float] = {o: 0.0 for o in outlets}
    skus: dict[str, set[str]] = {o: set() for o in outlets}
    categories: dict[str, set[str]] = {o: set() for o in outlets}
    days: dict[str, set[date]] = {o: set() for o in outlets}
    for line in lines:
        if line.outlet_id not in outlets:
            continue
        value[line.outlet_id] += line.value
        skus[line.outlet_id].add(line.product_id)
        product: ProductInfo | None = products.get(line.product_id)
        if product:
            categories[line.outlet_id].add(product.category_id)
        days[line.outlet_id].add(line.order_date)
    by_channel: dict[str, list[float]] = {}
    for outlet in outlets.values():
        by_channel.setdefault(outlet.channel_id, []).append(value[outlet.id] / months)
    latest_share = _latest_own_share(session, organization_id)
    features = {}
    for outlet in outlets.values():
        monthly = value[outlet.id] / months
        features[outlet.id] = {
            "monthly_sales_value": round(monthly, 2),
            "sales_percentile_in_channel": classification.percentile(monthly, by_channel[outlet.channel_id]),
            "distinct_skus": float(len(skus[outlet.id])),
            "distinct_categories": float(len(categories[outlet.id])),
            "order_frequency_per_month": round(len(days[outlet.id]) / months, 2),
            "own_share_of_shelf": latest_share.get(outlet.id),
            "shelf_meters": outlet.shelf_meters,
            "size_sqft": outlet.size_sqft,
        }
    return features


def _latest_own_share(session: Session, organization_id: str) -> dict[str, float]:
    rows = session.execute(
        select(ShelfMeasurement.outlet_id, ShelfMeasurement.value, ShelfMeasurement.computed_at)
        .where(ShelfMeasurement.organization_id == organization_id, ShelfMeasurement.metric == "share_of_shelf",
               ShelfMeasurement.scope_type == "own", ShelfMeasurement.basis == "verified")
        .order_by(ShelfMeasurement.computed_at)
    )
    return {outlet_id: value for outlet_id, value, _ in rows}


def classify_outlets(session: Session, organization_id: str, data_origin: str, as_of: date | None = None) -> int:
    """Run the active scheme's rules for every outlet. Writes a row only when the result changes."""
    as_of = as_of or date.today()
    scheme = loaders.active_scheme(session, organization_id)
    if scheme is None:
        return 0
    classes = [classification.ClassSpec(c.id, c.code, c.label, c.rank, c.criteria) for c in session.execute(
        select(OutletClass).where(OutletClass.scheme_id == scheme.id)).scalars()]
    features = outlet_features(session, organization_id, as_of)
    previous = {}
    for row in session.execute(
        select(OutletClassification).where(OutletClassification.scheme_id == scheme.id,
                                           OutletClassification.source == "rule")
        .order_by(OutletClassification.assessed_at)
    ).scalars():
        previous[row.outlet_id] = row
    written = 0
    for outlet_id, values in features.items():
        result = classification.classify(classes, values)
        if result is None:
            continue
        prior = previous.get(outlet_id)
        if prior and prior.class_id == result.class_id and abs(prior.confidence - result.confidence) < 1e-6:
            continue
        session.add(OutletClassification(
            organization_id=organization_id, data_origin=data_origin, outlet_id=outlet_id, scheme_id=scheme.id,
            class_id=result.class_id, source="rule", confidence=result.confidence,
            evidence={**result.evidence, "as_of": as_of.isoformat()},
            generator_version=classification.GENERATOR_VERSION,
        ))
        written += 1
    session.flush()
    return written


def override_classification(session: Session, principal: Principal, outlet_id: str, class_id: str, note: str) -> OutletClassification:
    cls = session.get(OutletClass, class_id)
    if cls is None or cls.organization_id != principal.organization_id:
        raise ValueError("Unknown outlet class")
    row = OutletClassification(
        organization_id=principal.organization_id, data_origin=principal.data_origin, outlet_id=outlet_id,
        scheme_id=cls.scheme_id, class_id=class_id, source="human", confidence=1.0,
        evidence={"note": note, "by": principal.user_id}, assessed_by_user_id=principal.user_id,
    )
    session.add(row)
    session.flush()
    audit.record(session, principal, "classification.override", "outlet", outlet_id, {"class_id": class_id, "note": note})
    return row
