"""Product catalogue. Own and competitor products share one normalised structure.

A product is "own" when its manufacturer has ``is_own = True``. Keeping both in
the same tables makes own-vs-competitor comparison a query, not a special case.
"""

from __future__ import annotations

from datetime import date

from sqlalchemy import JSON, Boolean, Date, Float, ForeignKey, Numeric, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .base import Base, Entity


class Manufacturer(Base, Entity):
    __tablename__ = "manufacturer"
    __table_args__ = (UniqueConstraint("organization_id", "code"),)

    code: Mapped[str] = mapped_column(String(32))
    name: Mapped[str] = mapped_column(String(200))
    is_own: Mapped[bool] = mapped_column(Boolean, default=False)
    is_verified: Mapped[bool] = mapped_column(Boolean, default=True)


class Brand(Base, Entity):
    __tablename__ = "brand"
    __table_args__ = (UniqueConstraint("organization_id", "code"),)

    code: Mapped[str] = mapped_column(String(32))
    name: Mapped[str] = mapped_column(String(200))
    name_bn: Mapped[str | None] = mapped_column(String(200))
    manufacturer_id: Mapped[str] = mapped_column(ForeignKey("manufacturer.id"), index=True)
    # A sub-brand points at its parent brand.
    parent_id: Mapped[str | None] = mapped_column(ForeignKey("brand.id"))

    manufacturer: Mapped[Manufacturer] = relationship()


class Category(Base, Entity):
    __tablename__ = "category"
    __table_args__ = (UniqueConstraint("organization_id", "code"),)

    code: Mapped[str] = mapped_column(String(32))
    name: Mapped[str] = mapped_column(String(200))
    name_bn: Mapped[str | None] = mapped_column(String(200))
    parent_id: Mapped[str | None] = mapped_column(ForeignKey("category.id"))
    # Materialised path ("/personal-care/skin-cleansing/") for subtree queries.
    path: Mapped[str] = mapped_column(String(500), index=True)
    level: Mapped[int] = mapped_column(default=0)


class Product(Base, Entity):
    """A SKU — own or competitor."""

    __tablename__ = "product"
    __table_args__ = (UniqueConstraint("organization_id", "sku"),)

    sku: Mapped[str] = mapped_column(String(64))
    name: Mapped[str] = mapped_column(String(300))
    name_bn: Mapped[str | None] = mapped_column(String(300))
    brand_id: Mapped[str] = mapped_column(ForeignKey("brand.id"), index=True)
    # Denormalised from brand for query speed; kept consistent by the catalogue service.
    manufacturer_id: Mapped[str] = mapped_column(ForeignKey("manufacturer.id"), index=True)
    category_id: Mapped[str] = mapped_column(ForeignKey("category.id"), index=True)
    pack_size: Mapped[float | None] = mapped_column(Float)
    pack_unit: Mapped[str | None] = mapped_column(String(16))
    # Configurable segment label, e.g. economy / mass / premium.
    price_tier: Mapped[str | None] = mapped_column(String(32))
    barcode: Mapped[str | None] = mapped_column(String(32), index=True)
    attributes: Mapped[dict] = mapped_column(JSON, default=dict)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    # Competitor SKUs created from field observations start unverified.
    is_verified: Mapped[bool] = mapped_column(Boolean, default=True)
    launched_on: Mapped[date | None] = mapped_column(Date)
    discontinued_on: Mapped[date | None] = mapped_column(Date)

    brand: Mapped[Brand] = relationship()
    manufacturer: Mapped[Manufacturer] = relationship()
    category: Mapped[Category] = relationship()


class ProductPrice(Base, Entity):
    __tablename__ = "product_price"

    product_id: Mapped[str] = mapped_column(ForeignKey("product.id"), index=True)
    price_type: Mapped[str] = mapped_column(String(16))  # mrp | trade
    amount: Mapped[float] = mapped_column(Numeric(12, 2))
    currency: Mapped[str] = mapped_column(String(3), default="BDT")
    effective_from: Mapped[date] = mapped_column(Date)
    effective_to: Mapped[date | None] = mapped_column(Date)


class PackagingVersion(Base, Entity):
    __tablename__ = "packaging_version"

    product_id: Mapped[str] = mapped_column(ForeignKey("product.id"), index=True)
    label: Mapped[str] = mapped_column(String(64))
    introduced_on: Mapped[date | None] = mapped_column(Date)
    retired_on: Mapped[date | None] = mapped_column(Date)
    notes: Mapped[str | None] = mapped_column(String(500))


class ReferenceImage(Base, Entity):
    __tablename__ = "reference_image"

    product_id: Mapped[str] = mapped_column(ForeignKey("product.id"), index=True)
    packaging_version_id: Mapped[str | None] = mapped_column(ForeignKey("packaging_version.id"))
    blob_key: Mapped[str] = mapped_column(String(300))
    sha256: Mapped[str] = mapped_column(String(64))
    view: Mapped[str] = mapped_column(String(16), default="front")
