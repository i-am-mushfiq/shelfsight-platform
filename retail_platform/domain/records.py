"""Plain data carried into domain calculations. No ORM, no I/O."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date


@dataclass(frozen=True, slots=True)
class ProductInfo:
    id: str
    sku: str
    name: str
    brand_id: str
    brand_name: str
    manufacturer_id: str
    manufacturer_name: str
    is_own: bool
    category_id: str
    category_name: str
    price_tier: str | None = None
    pack_size: float | None = None
    pack_unit: str | None = None
    mrp: float | None = None
    trade_price: float | None = None
    is_active: bool = True
    # Orders are rounded up to this many units (e.g. a dozen); 1 = loose units.
    order_multiple: int = 1


@dataclass(frozen=True, slots=True)
class OutletInfo:
    id: str
    code: str
    name: str
    channel_id: str
    channel_path: str
    territory_id: str
    class_id: str | None = None
    class_label: str | None = None
    shelf_meters: float | None = None
    size_sqft: float | None = None


@dataclass(frozen=True, slots=True)
class OrderLine:
    outlet_id: str
    product_id: str
    order_date: date
    quantity: int
    value: float


@dataclass(frozen=True, slots=True)
class Target:
    id: str
    channel_id: str | None
    outlet_class_id: str | None
    category_id: str | None
    dimension: str  # brand | category | price_tier
    dimension_value: str
    target_share: float
    tolerance: float


@dataclass(frozen=True, slots=True)
class CoreItem:
    id: str
    channel_id: str | None
    outlet_class_id: str | None
    product_id: str
    min_facings: int
    priority: int


@dataclass(frozen=True, slots=True)
class Facing:
    """A detected facing as seen by domain logic (after human review where available)."""

    id: str
    capture_id: str
    label: str  # own | competitor | unknown | rejected
    product_id: str | None
    manufacturer_id: str | None
    confidence: float
    verified: bool
    y_center: float
    shelf_row: int | None = None
    shelf_rows_total: int | None = None
    category_id: str | None = None


@dataclass(slots=True)
class Gap:
    kind: str  # missing_core | missing_vs_peers | under_indexed | mix_under_target | mix_over_target
    message: str
    evidence: dict
    product_id: str | None = None
    dimension: str | None = None
    dimension_value: str | None = None
    expected_monthly_units: float | None = None
    expected_monthly_value: float | None = None
    priority: int = 2
    confidence: float = 0.5
    extra: dict = field(default_factory=dict)


@dataclass(frozen=True, slots=True)
class ShelfStock:
    """What one visit's photos show about stock, as ordering and availability logic need it.

    covered_categories: categories whose shelf was photographed. A photo tagged with a
      category covers it and its sub-categories; an untagged ("mixed rack") photo covers the
      categories of the products identified on it. Products outside these were not checked.
    facings_by_product: identified facings per product (boxes a human rejected excluded).
    unidentified_by_category: facings not identified at SKU level that could belong to the
      category's products (facings known to be competitors are not counted).
    """

    visit_id: str
    covered_categories: frozenset[str]
    facings_by_product: dict[str, int]
    unidentified_by_category: dict[str, int]
    verified_ratio: float
    model_versions: tuple[str, ...] = ()
