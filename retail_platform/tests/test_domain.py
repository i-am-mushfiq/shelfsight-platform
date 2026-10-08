from datetime import date, timedelta

import pytest

from retail_platform.domain import classification, orders, placement, portfolio, recommendations, shelf
from retail_platform.domain.records import CoreItem, Facing, OrderLine, OutletInfo, ProductInfo, Target

AS_OF = date(2026, 10, 1)


def product(pid, brand="meril", category="soap", own=True, tier="mass", mrp=50.0, pack=100.0):
    return ProductInfo(
        id=pid, sku=pid.upper(), name=f"Product {pid}", brand_id=brand, brand_name=brand.title(),
        manufacturer_id="sq" if own else "uni", manufacturer_name="Square" if own else "Unilever",
        is_own=own, category_id=category, category_name=category.title(), price_tier=tier,
        pack_size=pack, pack_unit="g", mrp=mrp,
    )


def outlet(oid, channel="gt", cls=None):
    return OutletInfo(id=oid, code=oid, name=oid, channel_id=channel, channel_path=f"/{channel}/",
                      territory_id="t1", class_id=cls, class_label=cls)


def line(oid, pid, qty, days_ago=10, price=10.0):
    return OrderLine(oid, pid, AS_OF - timedelta(days=days_ago), qty, qty * price)


@pytest.fixture
def world():
    products = {p.id: p for p in [
        product("a"), product("b", brand="sepnil", category="handwash"), product("c", brand="jui", category="oil"),
        product("x", own=False),
    ]}
    outlets = {o.id: o for o in [outlet("o0")] + [outlet(f"p{i}") for i in range(8)] + [outlet("mt1", channel="mt")]}
    lines = [line("o0", "a", 30), line("o0", "b", 3)]
    for i in range(8):
        lines.append(line(f"p{i}", "a", 30))
        lines.append(line(f"p{i}", "b", 30))
        if i < 6:
            lines.append(line(f"p{i}", "c", 18))
    lines.append(line("o0", "a", 999, days_ago=200))  # outside window, must be ignored
    return products, outlets, lines


def test_mix_shares_sum_to_one_and_ignore_competitors(world):
    products, _, lines = world
    lines = lines + [OrderLine("o0", "x", AS_OF, 100, 1000.0)]
    mix = portfolio.compute_mix([l for l in lines if l.outlet_id == "o0" and l.order_date > AS_OF - timedelta(days=90)], products, "brand")
    assert pytest.approx(sum(e.value_share for e in mix), abs=1e-3) == 1.0
    assert {e.key for e in mix} == {"meril", "sepnil"}


def test_missing_sku_vs_peers_with_evidence(world):
    products, outlets, lines = world
    analysis = portfolio.analyze_outlet(outlets["o0"], outlets, products, lines, [], [], AS_OF)
    missing = [g for g in analysis.gaps if g.kind == "missing_vs_peers"]
    assert [g.product_id for g in missing] == ["c"]
    gap = missing[0]
    assert gap.evidence["peer_penetration"] == pytest.approx(0.75)
    assert gap.evidence["peer_group"]["size"] == 8  # mt1 is another channel
    assert gap.expected_monthly_units == pytest.approx(18 / (90 / 30.44), rel=1e-2)
    assert "75% of 8 comparable outlets" in gap.message


def test_under_indexed_sku(world):
    products, outlets, lines = world
    analysis = portfolio.analyze_outlet(outlets["o0"], outlets, products, lines, [], [], AS_OF)
    under = [g for g in analysis.gaps if g.kind == "under_indexed"]
    assert [g.product_id for g in under] == ["b"]


def test_window_excludes_old_orders(world):
    products, outlets, lines = world
    analysis = portfolio.analyze_outlet(outlets["o0"], outlets, products, lines, [], [], AS_OF)
    assert analysis.totals["units"] == 33


def test_core_item_missing_reported_once(world):
    products, outlets, lines = world
    core = [CoreItem("core1", "gt", None, "c", 2, 1)]
    analysis = portfolio.analyze_outlet(outlets["o0"], outlets, products, lines, [], core, AS_OF)
    kinds = [g.kind for g in analysis.gaps if g.product_id == "c"]
    assert kinds == ["missing_core"]


def test_target_most_specific_scope_wins(world):
    products, outlets, lines = world
    targets = [
        Target("t-global", None, None, None, "brand", "meril", 0.5, 0.05),
        Target("t-gt", "gt", None, None, "brand", "meril", 0.95, 0.02),
    ]
    analysis = portfolio.analyze_outlet(outlets["o0"], outlets, products, lines, targets, [], AS_OF)
    entry = analysis.target_mix["brand"][0]
    assert entry["target_id"] == "t-gt"
    gap = next(g for g in analysis.gaps if g.kind == "mix_under_target")
    assert gap.evidence["target_id"] == "t-gt"


def test_too_few_peers_suppresses_peer_gaps(world):
    products, outlets, lines = world
    small = {k: v for k, v in outlets.items() if k in {"o0", "p0", "p1"}}
    analysis = portfolio.analyze_outlet(outlets["o0"], small, products, lines, [], [], AS_OF)
    assert not [g for g in analysis.gaps if g.kind in {"missing_vs_peers", "under_indexed"}]


def test_recommendations_carry_evidence_and_dedupe_key(world):
    products, outlets, lines = world
    analysis = portfolio.analyze_outlet(outlets["o0"], outlets, products, lines, [], [], AS_OF)
    drafts = recommendations.from_portfolio("o0", analysis, products)
    add = next(d for d in drafts if d.type == "add_sku")
    assert add.dedupe_key == "o0:add_sku:c"
    assert add.evidence["peer_group"]["basis"]
    assert add.suggested_quantity == 6
    assert 0 < add.confidence < 1


# --- shelf -------------------------------------------------------------------------------

def facing(fid, label, y=0.5, row=None, total=None, product_id=None, manufacturer=None, verified=False, category="soap"):
    return Facing(fid, "cap", label, product_id, manufacturer or ("sq" if label == "own" else "uni" if label == "competitor" else None),
                  0.9, verified, y, row, total, category)


def test_shelf_rows_cluster_by_height():
    ys = [0.1, 0.12, 0.11, 0.45, 0.46, 0.8, 0.82]
    rows, total = shelf.assign_shelf_rows(ys, [0.2] * len(ys))
    assert total == 3
    assert rows == [1, 1, 1, 2, 2, 3, 3]


@pytest.mark.parametrize("row,total,band", [(1, 5, "top"), (2, 5, "eye"), (3, 5, "eye"), (4, 5, "middle"), (5, 5, "bottom"), (1, 1, "eye")])
def test_bands(row, total, band):
    assert shelf.band_for(row, total) == band


def test_share_of_shelf_reports_uncertainty_range():
    facings = [facing("1", "own"), facing("2", "own"), facing("3", "competitor"), facing("4", "unknown"), facing("5", "rejected")]
    summary = shelf.summarize(facings, {"sq"})
    assert summary.total_facings == 4
    assert summary.share_of_shelf == 0.5
    assert summary.share_of_shelf_range == (0.5, 0.75)


def test_verified_basis_uses_only_reviewed():
    facings = [facing("1", "own", verified=True), facing("2", "competitor"), facing("3", "competitor", verified=True)]
    summary = shelf.summarize(facings, {"sq"}, basis="verified")
    assert summary.total_facings == 2
    assert summary.share_of_shelf == 0.5


# --- placement ---------------------------------------------------------------------------

def rule(**kw):
    defaults = dict(id="r1", channel_id="gt", channel_path="/gt/", category_id="soap", product_id=None, brand_id=None,
                    manufacturer_id=None, preferred_band="eye", min_facings=2, min_share_of_shelf=None, priority=1,
                    promo_required=False, description="Own soap at eye level")
    defaults.update(kw)
    return placement.RuleSpec(**defaults)


def test_placement_compliant_and_non_compliant():
    facings = [facing("1", "own", row=2, total=5), facing("2", "own", row=3, total=5), facing("3", "competitor", row=1, total=5)]
    ok = placement.evaluate([rule()], facings, "/gt/grocery/", {}, {"sq"})
    assert ok[0].status == "compliant"
    bad = placement.evaluate([rule(min_facings=3, min_share_of_shelf=0.8)], facings, "/gt/", {}, {"sq"})
    assert bad[0].status == "non_compliant"
    assert len(bad[0].observed["failures"]) == 2


def test_product_rule_not_evaluable_without_sku_identity():
    facings = [facing("1", "own", row=2, total=5)]
    results = placement.evaluate([rule(product_id="a")], facings, "/gt/", {}, {"sq"})
    assert results[0].status == "not_evaluable"
    assert placement.compliance_score(results) is None


def test_rule_for_other_channel_is_ignored():
    results = placement.evaluate([rule(channel_path="/mt/")], [facing("1", "own", row=2, total=5)], "/gt/", {}, {"sq"})
    assert results == []


# --- classification ----------------------------------------------------------------------

CLASSES = [
    classification.ClassSpec("A", "A", "High potential", 1, [
        {"feature": "sales_percentile_in_channel", "op": ">=", "value": 0.8},
        {"feature": "distinct_skus", "op": ">=", "value": 10},
    ]),
    classification.ClassSpec("B", "B", "Core", 2, [{"feature": "sales_percentile_in_channel", "op": ">=", "value": 0.4}]),
    classification.ClassSpec("C", "C", "Developing", 3, []),
]


def test_classification_first_matching_class_with_evidence():
    result = classification.classify(CLASSES, {"sales_percentile_in_channel": 0.9, "distinct_skus": 12})
    assert result.class_code == "A"
    assert result.confidence == 1.0
    assert len(result.evidence["reasons"]) == 2


def test_missing_feature_lowers_confidence_and_never_matches_on_unknown_only():
    result = classification.classify(CLASSES, {"sales_percentile_in_channel": 0.9, "distinct_skus": None})
    # A cannot be confirmed (one criterion unknown) -> still matches A only if evaluable criteria pass
    assert result.class_code == "A"
    assert result.confidence < 1.0
    result = classification.classify(CLASSES, {})
    assert result.class_code == "C"
    assert result.confidence == 0.0


def test_percentile():
    assert classification.percentile(5, [1, 2, 3, 4, 5]) == 0.8
    assert classification.percentile(1, []) == 0.0


# --- orders ------------------------------------------------------------------------------

def test_suggested_order_combines_replenishment_and_recommendations(world):
    products, _, lines = world
    recs = [orders.RecommendationRef("r1", "add_sku", "c", 6, "open"),
            orders.RecommendationRef("r2", "add_sku", "a", 4, "rejected")]
    suggestion = orders.suggest("o0", lines, products, recs, {"c"}, AS_OF)
    by_product = {s.product_id: s for s in suggestion}
    assert by_product["a"].quantity == 30
    assert by_product["c"].quantity == 6
    assert {s["source"] for s in by_product["c"].sources} == {"recommendation", "promotion"}


def test_rule_on_subcategory_is_not_evaluable_when_photo_only_has_parent_category():
    descendants = {"skin": {"skin", "soap"}, "soap": {"soap"}}
    facings = [facing("1", "own", row=2, total=5, category="skin")]
    results = placement.evaluate([rule(product_id="a")], facings, "/gt/", {}, {"sq"}, descendants)
    assert [r.status for r in results] == ["not_evaluable"]
    # ...while a rule on the parent category is evaluated from the same facings.
    parent = placement.evaluate([rule(category_id="skin", min_facings=1)], facings, "/gt/", {}, {"sq"}, descendants)
    assert parent[0].status == "compliant"
