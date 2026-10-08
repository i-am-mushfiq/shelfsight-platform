"""Own vs competitor analysis from shelf evidence and field observations.

Company order data contains own products only, so competitor intelligence here is
built from what was *observed* (verified detections, manual observations). Each
figure states its basis and sample size.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass

from .shelf import ShelfSummary
from .records import ProductInfo

GENERATOR_VERSION = "competitor-1.0"


@dataclass(frozen=True, slots=True)
class ObservedProduct:
    """A product seen in an outlet (from vision or a manual observation), with optional price."""

    outlet_id: str
    product_id: str | None
    manufacturer_id: str
    category_id: str | None
    facings: int
    observed_price: float | None
    source: str


@dataclass(slots=True)
class ManufacturerPresence:
    manufacturer_id: str
    name: str
    is_own: bool
    facings: int
    share_of_shelf: float | None
    skus: int
    share_of_assortment: float | None
    categories: list[str]


def presence_by_manufacturer(
    observations: list[ObservedProduct],
    manufacturers: dict[str, tuple[str, bool]],
) -> list[ManufacturerPresence]:
    facings: dict[str, int] = defaultdict(int)
    skus: dict[str, set[str]] = defaultdict(set)
    categories: dict[str, set[str]] = defaultdict(set)
    for obs in observations:
        facings[obs.manufacturer_id] += obs.facings
        if obs.product_id:
            skus[obs.manufacturer_id].add(obs.product_id)
        if obs.category_id:
            categories[obs.manufacturer_id].add(obs.category_id)
    total_facings = sum(facings.values())
    total_skus = sum(len(s) for s in skus.values())
    result = []
    for manufacturer_id in set(facings) | set(skus):
        name, is_own = manufacturers.get(manufacturer_id, (manufacturer_id, False))
        result.append(ManufacturerPresence(
            manufacturer_id=manufacturer_id, name=name, is_own=is_own,
            facings=facings[manufacturer_id],
            share_of_shelf=round(facings[manufacturer_id] / total_facings, 4) if total_facings else None,
            skus=len(skus[manufacturer_id]),
            share_of_assortment=round(len(skus[manufacturer_id]) / total_skus, 4) if total_skus else None,
            categories=sorted(categories[manufacturer_id]),
        ))
    return sorted(result, key=lambda p: p.facings, reverse=True)


def portfolio_overlap(
    observations: list[ObservedProduct], products: dict[str, ProductInfo]
) -> dict[str, list[dict]]:
    """Per category: where competitors are present and own is absent (own gap) and vice versa."""
    present: dict[str, dict[str, set[str]]] = defaultdict(lambda: {"own": set(), "competitor": set()})
    for obs in observations:
        if not obs.category_id:
            continue
        product = products.get(obs.product_id or "")
        is_own = product.is_own if product else False
        present[obs.category_id]["own" if is_own else "competitor"].add(obs.manufacturer_id)
    own_gaps, competitor_gaps, contested = [], [], []
    for category_id, sides in present.items():
        entry = {"category_id": category_id, "own_manufacturers": sorted(sides["own"]),
                 "competitor_manufacturers": sorted(sides["competitor"])}
        if sides["competitor"] and not sides["own"]:
            own_gaps.append(entry)
        elif sides["own"] and not sides["competitor"]:
            competitor_gaps.append(entry)
        else:
            contested.append(entry)
    return {"own_gaps": own_gaps, "competitor_gaps": competitor_gaps, "contested": contested}


def price_positioning(
    observations: list[ObservedProduct], products: dict[str, ProductInfo]
) -> list[dict]:
    """Compare observed competitor price per unit size against own MRP per unit in the same category.

    index = competitor price per unit / own average price per unit (1.0 = parity).
    """
    own_unit_prices: dict[str, list[float]] = defaultdict(list)
    for product in products.values():
        if product.is_own and product.mrp and product.pack_size:
            own_unit_prices[product.category_id].append(product.mrp / product.pack_size)
    rows = []
    for obs in observations:
        product = products.get(obs.product_id or "")
        if obs.observed_price is None or product is None or product.is_own or not product.pack_size:
            continue
        own = own_unit_prices.get(product.category_id)
        if not own:
            continue
        own_avg = sum(own) / len(own)
        unit = obs.observed_price / product.pack_size
        rows.append({
            "product_id": product.id, "sku": product.sku, "name": product.name,
            "manufacturer": product.manufacturer_name, "category": product.category_name,
            "observed_price": obs.observed_price, "price_per_unit": round(unit, 4),
            "own_avg_price_per_unit": round(own_avg, 4), "index_vs_own": round(unit / own_avg, 3),
            "outlet_id": obs.outlet_id, "source": obs.source,
        })
    return rows


def summary_to_observations(
    outlet_id: str,
    summary: ShelfSummary,
    products: dict[str, ProductInfo],
) -> list[ObservedProduct]:
    """Turn a shelf summary into observed products (manufacturer-level when SKU is unknown)."""
    result: list[ObservedProduct] = []
    accounted: dict[str, int] = defaultdict(int)
    for product_id, count in summary.facings_by_product.items():
        product = products.get(product_id)
        if product is None:
            continue
        accounted[product.manufacturer_id] += count
        result.append(ObservedProduct(outlet_id, product_id, product.manufacturer_id,
                                      product.category_id, count, None, "vision"))
    for manufacturer_id, count in summary.facings_by_manufacturer.items():
        remaining = count - accounted.get(manufacturer_id, 0)
        if remaining > 0:
            result.append(ObservedProduct(outlet_id, None, manufacturer_id, None, remaining, None, "vision"))
    return result
