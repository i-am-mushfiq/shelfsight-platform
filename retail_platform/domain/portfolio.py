"""Portfolio ratio intelligence: current mix vs target vs channel vs peers, and the gaps.

Answers three questions for an outlet:
  * what does it currently carry (from own-brand order history)?
  * what should it carry (targets, core assortment, channel and peer behaviour)?
  * what is missing, under-indexed or over-indexed — with the evidence?

Order data covers own products only, so every share here is a share of the
*own* portfolio ("own portfolio mix"), never a market share.
"""

from __future__ import annotations

import math
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date, timedelta

from .records import CoreItem, Gap, OrderLine, OutletInfo, ProductInfo, Target

GENERATOR_VERSION = "portfolio-1.0"
DAYS_PER_MONTH = 30.44


@dataclass(frozen=True, slots=True)
class PortfolioConfig:
    window_days: int = 90
    min_peers: int = 5
    # A SKU is "expected" when at least this share of peers bought it in the window.
    peer_penetration_threshold: float = 0.5
    # An outlet is under-indexed on a SKU it buys below this fraction of the peer buyer average.
    under_index_ratio: float = 0.5
    sales_bands: int = 3


@dataclass(slots=True)
class MixEntry:
    key: str
    label: str
    value: float
    units: int
    value_share: float


@dataclass(slots=True)
class SkuStat:
    product_id: str
    sku: str
    name: str
    outlet_monthly_units: float
    outlet_monthly_value: float
    peer_penetration: float
    peer_buyers: int
    peer_avg_monthly_units: float  # among peers that bought it
    channel_penetration: float


@dataclass(slots=True)
class PortfolioAnalysis:
    outlet_id: str
    window: dict
    generator_version: str
    totals: dict
    current_mix: dict[str, list[MixEntry]]
    target_mix: dict[str, list[dict]]
    channel_benchmark: dict[str, list[MixEntry]]
    peer_benchmark: dict[str, list[MixEntry]]
    peer_group: dict
    sku_stats: list[SkuStat]
    gaps: list[Gap] = field(default_factory=list)


def _months(window_days: int) -> float:
    return window_days / DAYS_PER_MONTH


def _dimension_key(product: ProductInfo, dimension: str) -> tuple[str, str]:
    if dimension == "brand":
        return product.brand_id, product.brand_name
    if dimension == "category":
        return product.category_id, product.category_name
    if dimension == "price_tier":
        tier = product.price_tier or "unclassified"
        return tier, tier
    raise ValueError(f"Unknown dimension {dimension}")


def compute_mix(
    lines: list[OrderLine], products: dict[str, ProductInfo], dimension: str
) -> list[MixEntry]:
    values: dict[str, float] = defaultdict(float)
    units: dict[str, int] = defaultdict(int)
    labels: dict[str, str] = {}
    for line in lines:
        product = products.get(line.product_id)
        if product is None or not product.is_own:
            continue
        key, label = _dimension_key(product, dimension)
        values[key] += line.value
        units[key] += line.quantity
        labels[key] = label
    total = sum(values.values())
    entries = [
        MixEntry(key, labels[key], round(values[key], 2), units[key],
                 round(values[key] / total, 4) if total else 0.0)
        for key in values
    ]
    return sorted(entries, key=lambda e: e.value_share, reverse=True)


def _average_mix(
    per_outlet_lines: dict[str, list[OrderLine]],
    outlet_ids: list[str],
    products: dict[str, ProductInfo],
    dimension: str,
) -> list[MixEntry]:
    """Mean of each outlet's shares, so one large outlet does not define the benchmark."""
    sums: dict[str, float] = defaultdict(float)
    labels: dict[str, str] = {}
    contributing = 0
    for outlet_id in outlet_ids:
        mix = compute_mix(per_outlet_lines.get(outlet_id, []), products, dimension)
        if not mix:
            continue
        contributing += 1
        for entry in mix:
            sums[entry.key] += entry.value_share
            labels[entry.key] = entry.label
    if not contributing:
        return []
    entries = [
        MixEntry(key, labels[key], 0.0, 0, round(total / contributing, 4))
        for key, total in sums.items()
    ]
    return sorted(entries, key=lambda e: e.value_share, reverse=True)


def sales_bands(
    per_outlet_lines: dict[str, list[OrderLine]], outlet_ids: list[str], bands: int
) -> dict[str, int]:
    """Assign each outlet a sales band (0 = lowest) by own-portfolio value, within the given set."""
    ranked = sorted(outlet_ids, key=lambda oid: sum(l.value for l in per_outlet_lines.get(oid, [])))
    if not ranked:
        return {}
    return {oid: min(bands - 1, index * bands // len(ranked)) for index, oid in enumerate(ranked)}


def select_peers(
    outlet: OutletInfo,
    outlets: dict[str, OutletInfo],
    per_outlet_lines: dict[str, list[OrderLine]],
    config: PortfolioConfig,
) -> tuple[list[str], dict]:
    """Peers: same channel and same outlet class; fall back to same channel + sales band, then channel."""
    same_channel = [o.id for o in outlets.values() if o.channel_id == outlet.channel_id and o.id != outlet.id]
    if outlet.class_id:
        same_class = [oid for oid in same_channel if outlets[oid].class_id == outlet.class_id]
        if len(same_class) >= config.min_peers:
            return same_class, {
                "basis": "same channel and outlet class",
                "class": outlet.class_label, "size": len(same_class),
            }
    bands = sales_bands(per_outlet_lines, same_channel + [outlet.id], config.sales_bands)
    own_band = bands.get(outlet.id)
    same_band = [oid for oid in same_channel if bands.get(oid) == own_band]
    if len(same_band) >= config.min_peers:
        return same_band, {
            "basis": "same channel and sales band", "band": own_band,
            "bands": config.sales_bands, "size": len(same_band),
        }
    return same_channel, {
        "basis": "same channel (too few class/band peers)", "size": len(same_channel),
        "min_peers": config.min_peers,
    }


def applicable_targets(targets: list[Target], outlet: OutletInfo) -> list[Target]:
    """Most specific scope wins per (dimension, value, category): class+channel > channel > class > global."""
    def specificity(t: Target) -> int:
        return (2 if t.channel_id else 0) + (1 if t.outlet_class_id else 0)

    chosen: dict[tuple, Target] = {}
    for target in targets:
        if target.channel_id and target.channel_id != outlet.channel_id:
            continue
        if target.outlet_class_id and target.outlet_class_id != outlet.class_id:
            continue
        key = (target.dimension, target.dimension_value, target.category_id)
        if key not in chosen or specificity(target) > specificity(chosen[key]):
            chosen[key] = target
    return list(chosen.values())


def applicable_core(core: list[CoreItem], outlet: OutletInfo) -> list[CoreItem]:
    chosen: dict[str, CoreItem] = {}
    for item in core:
        if item.channel_id and item.channel_id != outlet.channel_id:
            continue
        if item.outlet_class_id and item.outlet_class_id != outlet.class_id:
            continue
        current = chosen.get(item.product_id)
        if current is None or item.priority < current.priority:
            chosen[item.product_id] = item
    return list(chosen.values())


def _peer_confidence(penetration: float, peers: int) -> float:
    """Heuristic: stronger when more peers agree and the peer group is larger. Not calibrated."""
    if peers <= 0:
        return 0.0
    return round(min(0.95, penetration * (1 - 1 / math.sqrt(peers + 1))), 3)


def analyze_outlet(
    outlet: OutletInfo,
    outlets: dict[str, OutletInfo],
    products: dict[str, ProductInfo],
    lines: list[OrderLine],
    targets: list[Target],
    core: list[CoreItem],
    as_of: date,
    config: PortfolioConfig | None = None,
) -> PortfolioAnalysis:
    config = config or PortfolioConfig()
    start = as_of - timedelta(days=config.window_days)
    months = _months(config.window_days)
    window_lines = [l for l in lines if start < l.order_date <= as_of]
    per_outlet: dict[str, list[OrderLine]] = defaultdict(list)
    for line in window_lines:
        per_outlet[line.outlet_id].append(line)

    own_lines = per_outlet.get(outlet.id, [])
    price_of = _unit_price_lookup(window_lines, products)
    peers, peer_group = select_peers(outlet, outlets, per_outlet, config)
    channel_ids = [o.id for o in outlets.values() if o.channel_id == outlet.channel_id and o.id != outlet.id]

    dimensions = ("brand", "category", "price_tier")
    current = {d: compute_mix(own_lines, products, d) for d in dimensions}
    channel_bench = {d: _average_mix(per_outlet, channel_ids, products, d) for d in dimensions}
    peer_bench = {d: _average_mix(per_outlet, peers, products, d) for d in dimensions}

    # --- SKU statistics -------------------------------------------------------------------
    def units_by_product(outlet_ids: list[str]) -> dict[str, dict[str, int]]:
        table: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
        for oid in outlet_ids:
            for line in per_outlet.get(oid, []):
                table[line.product_id][oid] += line.quantity
        return table

    peer_units = units_by_product(peers)
    channel_units = units_by_product(channel_ids)
    outlet_units: dict[str, int] = defaultdict(int)
    outlet_value: dict[str, float] = defaultdict(float)
    for line in own_lines:
        outlet_units[line.product_id] += line.quantity
        outlet_value[line.product_id] += line.value

    sku_stats: list[SkuStat] = []
    for product in products.values():
        if not product.is_own or not product.is_active:
            continue
        buyers = peer_units.get(product.id, {})
        buyer_count = sum(1 for qty in buyers.values() if qty > 0)
        channel_buyers = sum(1 for qty in channel_units.get(product.id, {}).values() if qty > 0)
        sku_stats.append(SkuStat(
            product_id=product.id, sku=product.sku, name=product.name,
            outlet_monthly_units=round(outlet_units.get(product.id, 0) / months, 2),
            outlet_monthly_value=round(outlet_value.get(product.id, 0.0) / months, 2),
            peer_penetration=round(buyer_count / len(peers), 4) if peers else 0.0,
            peer_buyers=buyer_count,
            peer_avg_monthly_units=round(sum(buyers.values()) / buyer_count / months, 2) if buyer_count else 0.0,
            channel_penetration=round(channel_buyers / len(channel_ids), 4) if channel_ids else 0.0,
        ))

    # --- targets ---------------------------------------------------------------------------
    targets_here = applicable_targets(targets, outlet)
    target_mix: dict[str, list[dict]] = defaultdict(list)
    gaps: list[Gap] = []
    for target in targets_here:
        scoped_lines = own_lines
        if target.category_id:
            scoped_lines = [l for l in own_lines if products.get(l.product_id) and products[l.product_id].category_id == target.category_id]
        mix = {e.key: e for e in compute_mix(scoped_lines, products, target.dimension)}
        actual = mix[target.dimension_value].value_share if target.dimension_value in mix else 0.0
        label = mix[target.dimension_value].label if target.dimension_value in mix else _label_for(products, target)
        target_mix[target.dimension].append({
            "key": target.dimension_value, "label": label, "target_share": target.target_share,
            "tolerance": target.tolerance, "actual_share": actual, "category_id": target.category_id,
            "target_id": target.id,
        })
        if not scoped_lines:
            continue
        delta = actual - target.target_share
        if abs(delta) <= target.tolerance:
            continue
        kind = "mix_under_target" if delta < 0 else "mix_over_target"
        direction = "below" if delta < 0 else "above"
        gaps.append(Gap(
            kind=kind,
            message=(
                f"{label} is {actual:.0%} of this outlet's {target.dimension} mix, "
                f"{direction} the {target.target_share:.0%} target (±{target.tolerance:.0%})."
            ),
            dimension=target.dimension, dimension_value=target.dimension_value,
            priority=2 if delta < 0 else 3, confidence=0.8,
            evidence={
                "actual_share": actual, "target_share": target.target_share,
                "tolerance": target.tolerance, "target_id": target.id,
                "window_days": config.window_days,
                "peer_share": next((e.value_share for e in peer_bench.get(target.dimension, []) if e.key == target.dimension_value), None),
            },
        ))

    # --- SKU gaps --------------------------------------------------------------------------
    stats_by_product = {s.product_id: s for s in sku_stats}
    core_here = applicable_core(core, outlet)
    core_ids = {item.product_id for item in core_here}
    for item in core_here:
        stat = stats_by_product.get(item.product_id)
        product = products.get(item.product_id)
        if stat is None or product is None or stat.outlet_monthly_units > 0:
            continue
        expected_units = stat.peer_avg_monthly_units or None
        gaps.append(Gap(
            kind="missing_core", product_id=product.id, priority=item.priority,
            confidence=0.9,
            message=f"{product.name} is on the core assortment for this channel but was not ordered in the last {config.window_days} days.",
            expected_monthly_units=expected_units,
            expected_monthly_value=round(expected_units * price_of(product), 2) if expected_units else None,
            evidence={
                "core_item_id": item.id, "outlet_units_in_window": 0,
                "window_days": config.window_days,
                "peer_penetration": stat.peer_penetration, "peer_buyers": stat.peer_buyers,
                "peer_group": peer_group, "peer_avg_monthly_units": stat.peer_avg_monthly_units,
            },
        ))

    peer_count = len(peers)
    for stat in sku_stats:
        product = products[stat.product_id]
        if stat.product_id in core_ids and stat.outlet_monthly_units == 0:
            continue  # already reported as missing_core
        if peer_count < config.min_peers:
            continue
        if stat.outlet_monthly_units == 0 and stat.peer_penetration >= config.peer_penetration_threshold:
            gaps.append(Gap(
                kind="missing_vs_peers", product_id=product.id,
                priority=1 if stat.peer_penetration >= 0.75 else 2,
                confidence=_peer_confidence(stat.peer_penetration, peer_count),
                message=(
                    f"Outlet has 0 units of {product.name} in the last {config.window_days} days, but "
                    f"{stat.peer_penetration:.0%} of {peer_count} comparable outlets bought it "
                    f"(avg {stat.peer_avg_monthly_units:g} units/month among buyers)."
                ),
                expected_monthly_units=stat.peer_avg_monthly_units,
                expected_monthly_value=round(stat.peer_avg_monthly_units * price_of(product), 2),
                evidence={
                    "outlet_units_in_window": 0, "window_days": config.window_days,
                    "peer_penetration": stat.peer_penetration, "peer_buyers": stat.peer_buyers,
                    "peer_group": peer_group, "peer_avg_monthly_units": stat.peer_avg_monthly_units,
                    "channel_penetration": stat.channel_penetration,
                },
            ))
        elif (
            stat.outlet_monthly_units > 0
            and stat.peer_buyers >= config.min_peers
            and stat.outlet_monthly_units < stat.peer_avg_monthly_units * config.under_index_ratio
        ):
            uplift = round(stat.peer_avg_monthly_units - stat.outlet_monthly_units, 2)
            gaps.append(Gap(
                kind="under_indexed", product_id=product.id, priority=3,
                confidence=_peer_confidence(min(1.0, stat.peer_buyers / peer_count), peer_count),
                message=(
                    f"{product.name}: {stat.outlet_monthly_units:g} units/month here vs "
                    f"{stat.peer_avg_monthly_units:g} among {stat.peer_buyers} peer outlets that stock it."
                ),
                expected_monthly_units=uplift,
                expected_monthly_value=round(uplift * price_of(product), 2),
                evidence={
                    "outlet_monthly_units": stat.outlet_monthly_units,
                    "peer_avg_monthly_units": stat.peer_avg_monthly_units,
                    "peer_buyers": stat.peer_buyers, "peer_group": peer_group,
                    "window_days": config.window_days,
                },
            ))

    total_value = round(sum(l.value for l in own_lines), 2)
    return PortfolioAnalysis(
        outlet_id=outlet.id,
        window={"start": start.isoformat(), "end": as_of.isoformat(), "days": config.window_days},
        generator_version=GENERATOR_VERSION,
        totals={
            "value": total_value,
            "monthly_value": round(total_value / months, 2),
            "units": sum(l.quantity for l in own_lines),
            "order_days": len({l.order_date for l in own_lines}),
            "distinct_skus": len({l.product_id for l in own_lines}),
            "distinct_categories": len({products[l.product_id].category_id for l in own_lines if l.product_id in products}),
        },
        current_mix=current,
        target_mix=dict(target_mix),
        channel_benchmark=channel_bench,
        peer_benchmark=peer_bench,
        peer_group=peer_group,
        sku_stats=sorted(sku_stats, key=lambda s: s.peer_penetration, reverse=True),
        gaps=sorted(gaps, key=lambda g: (g.priority, -(g.expected_monthly_value or 0))),
    )


def _unit_price_lookup(lines: list[OrderLine], products: dict[str, ProductInfo]):  # type: ignore[no-untyped-def]
    """Average realised unit price per product from history; falls back to MRP."""
    qty: dict[str, int] = defaultdict(int)
    value: dict[str, float] = defaultdict(float)
    for line in lines:
        qty[line.product_id] += line.quantity
        value[line.product_id] += line.value

    def price_of(product: ProductInfo) -> float:
        if qty.get(product.id):
            return value[product.id] / qty[product.id]
        return product.mrp or 0.0

    return price_of


def _label_for(products: dict[str, ProductInfo], target: Target) -> str:
    for product in products.values():
        key, label = _dimension_key(product, target.dimension)
        if key == target.dimension_value:
            return label
    return target.dimension_value
