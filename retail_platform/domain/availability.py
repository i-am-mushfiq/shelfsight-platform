"""Core-assortment availability on the shelf, from one visit's photos.

A must-stock product is:
  on_shelf     seen with at least its minimum facings
  low          seen, but with fewer facings than required
  missing      not seen, although its category's shelf was photographed
  not_checked  its category's shelf was not photographed in this visit — never reported
               as missing, because absence of a photo is not absence of stock
"""

from __future__ import annotations

from dataclasses import dataclass

from .records import CoreItem, ProductInfo, ShelfStock

GENERATOR_VERSION = "availability-1.0"


@dataclass(slots=True)
class Availability:
    product_id: str
    status: str
    facings: int
    min_facings: int
    priority: int
    unidentified_nearby: int


def core_availability(core: list[CoreItem], products: dict[str, ProductInfo],
                      shelf: ShelfStock | None) -> list[Availability]:
    result = []
    for item in core:
        product = products.get(item.product_id)
        if product is None or not product.is_active:
            continue
        if shelf is None or product.category_id not in shelf.covered_categories:
            result.append(Availability(product.id, "not_checked", 0, item.min_facings, item.priority, 0))
            continue
        seen = shelf.facings_by_product.get(product.id, 0)
        status = "on_shelf" if seen >= item.min_facings else ("low" if seen else "missing")
        result.append(Availability(product.id, status, seen, item.min_facings, item.priority,
                                   shelf.unidentified_by_category.get(product.category_id, 0)))
    order = {"missing": 0, "low": 1, "on_shelf": 2, "not_checked": 3}
    return sorted(result, key=lambda a: (order[a.status], a.priority, products[a.product_id].name))
