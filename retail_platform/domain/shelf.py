"""Shelf metrics from detected facings.

Metric definitions (never conflated):
  share_of_shelf      own facings / all product facings in scope
  share_of_assortment distinct own SKUs present / distinct SKUs present
  facings             count of facings per product / manufacturer
  presence            whether a product was seen at all

Unknown facings (the model could not tell own from competitor) stay in the
denominator, and the result reports a [min, max] range so uncertainty is visible
instead of silently assumed away.
"""

from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass

from .records import Facing

GENERATOR_VERSION = "shelf-1.0"


def assign_shelf_rows(
    y_centers: list[float], heights: list[float], gap_ratio: float = 0.5
) -> tuple[list[int], int]:
    """Cluster facings into shelf rows by vertical centre (normalised 0..1, top = 0).

    Sorted by centre, a new row starts where consecutive centres are further apart than
    ``gap_ratio`` × the median facing height. Returns 1-based rows from the top and the count.
    """
    if not y_centers:
        return [], 0
    order = sorted(range(len(y_centers)), key=lambda i: y_centers[i])
    sorted_y = [y_centers[i] for i in order]
    sorted_heights = sorted(heights)
    median_height = sorted_heights[len(sorted_heights) // 2] if sorted_heights else 0.1
    threshold = max(0.02, gap_ratio * median_height)
    rows_sorted = [1]
    for previous, current in zip(sorted_y, sorted_y[1:]):
        rows_sorted.append(rows_sorted[-1] + (1 if current - previous > threshold else 0))
    rows = [0] * len(y_centers)
    for position, index in enumerate(order):
        rows[index] = rows_sorted[position]
    return rows, rows_sorted[-1]


def band_for(row: int | None, total: int | None) -> str | None:
    """Map a shelf row to a vertical band. Top shelf = 1.

    Relative position r = (row - 0.5) / total:
      r < 0.25 top · r < 0.6 eye · r < 0.8 middle · else bottom.
    On a 5-shelf gondola rows 2–3 are eye level, 4 is waist (middle), 5 bottom.
    """
    if row is None or not total:
        return None
    if total == 1:
        return "eye"
    relative = (row - 0.5) / total
    if relative < 0.25:
        return "top"
    if relative < 0.6:
        return "eye"
    if relative < 0.8:
        return "middle"
    return "bottom"


@dataclass(slots=True)
class ShelfSummary:
    basis: str
    total_facings: int
    own_facings: int
    competitor_facings: int
    unknown_facings: int
    share_of_shelf: float | None
    share_of_shelf_range: tuple[float, float] | None
    facings_by_manufacturer: dict[str, int]
    facings_by_product: dict[str, int]
    distinct_skus: int
    distinct_own_skus: int
    share_of_assortment: float | None
    verified_ratio: float


def summarize(facings: list[Facing], own_manufacturers: set[str], basis: str = "all") -> ShelfSummary:
    considered = [f for f in facings if f.label != "rejected"]
    if basis == "verified":
        considered = [f for f in considered if f.verified]
    total = len(considered)
    own = sum(f.label == "own" for f in considered)
    competitor = sum(f.label == "competitor" for f in considered)
    unknown = total - own - competitor
    by_manufacturer: Counter[str] = Counter(f.manufacturer_id for f in considered if f.manufacturer_id)
    by_product: Counter[str] = Counter(f.product_id for f in considered if f.product_id)
    skus = {f.product_id for f in considered if f.product_id}
    own_skus = {f.product_id for f in considered if f.product_id and f.manufacturer_id in own_manufacturers}
    reviewed = sum(f.verified for f in facings if f.label != "rejected")
    return ShelfSummary(
        basis=basis,
        total_facings=total,
        own_facings=own,
        competitor_facings=competitor,
        unknown_facings=unknown,
        share_of_shelf=round(own / total, 4) if total else None,
        share_of_shelf_range=(round(own / total, 4), round((own + unknown) / total, 4)) if total else None,
        facings_by_manufacturer=dict(by_manufacturer),
        facings_by_product=dict(by_product),
        distinct_skus=len(skus),
        distinct_own_skus=len(own_skus),
        share_of_assortment=round(len(own_skus) / len(skus), 4) if skus else None,
        verified_ratio=round(reviewed / max(1, len([f for f in facings if f.label != "rejected"])), 4),
    )


def facings_by_band(facings: list[Facing]) -> dict[str, dict[str, int]]:
    """{band: {manufacturer_id or label: count}} — basis for placement and visibility."""
    table: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for facing in facings:
        if facing.label == "rejected":
            continue
        band = band_for(facing.shelf_row, facing.shelf_rows_total) or "unknown"
        table[band][facing.manufacturer_id or facing.label] += 1
    return {band: dict(counts) for band, counts in table.items()}
