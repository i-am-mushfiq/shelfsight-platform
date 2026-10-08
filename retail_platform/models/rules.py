"""Versioned business configuration. Analyses record which rule set they used."""

from __future__ import annotations

from datetime import date

from sqlalchemy import Boolean, Date, Float, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from .base import Base, Entity


class RuleSet(Base, Entity):
    __tablename__ = "rule_set"

    kind: Mapped[str] = mapped_column(String(32))  # portfolio | assortment | placement
    name: Mapped[str] = mapped_column(String(200))
    version: Mapped[int] = mapped_column(Integer, default=1)
    status: Mapped[str] = mapped_column(String(16), default="draft")  # draft | active | retired
    effective_from: Mapped[date | None] = mapped_column(Date)
    notes: Mapped[str | None] = mapped_column(String(1000))


class PortfolioTarget(Base, Entity):
    """Target share of the own portfolio for one dimension value within a scope.

    scope: channel and/or outlet class (null = applies to all); optional category restricts
    the denominator to that category. dimension: brand | category | price_tier.
    """

    __tablename__ = "portfolio_target"

    rule_set_id: Mapped[str] = mapped_column(ForeignKey("rule_set.id"), index=True)
    channel_id: Mapped[str | None] = mapped_column(ForeignKey("channel.id"))
    outlet_class_id: Mapped[str | None] = mapped_column(ForeignKey("outlet_class.id"))
    category_id: Mapped[str | None] = mapped_column(ForeignKey("category.id"))
    dimension: Mapped[str] = mapped_column(String(16))
    dimension_value: Mapped[str] = mapped_column(String(64))
    target_share: Mapped[float] = mapped_column(Float)
    tolerance: Mapped[float] = mapped_column(Float, default=0.05)


class CoreAssortmentItem(Base, Entity):
    """Must-stock product for a channel / outlet class."""

    __tablename__ = "core_assortment_item"

    rule_set_id: Mapped[str] = mapped_column(ForeignKey("rule_set.id"), index=True)
    channel_id: Mapped[str | None] = mapped_column(ForeignKey("channel.id"))
    outlet_class_id: Mapped[str | None] = mapped_column(ForeignKey("outlet_class.id"))
    product_id: Mapped[str] = mapped_column(ForeignKey("product.id"))
    min_facings: Mapped[int] = mapped_column(Integer, default=1)
    priority: Mapped[int] = mapped_column(Integer, default=2)  # 1 = highest


class PlacementRule(Base, Entity):
    """Channel-specific placement expectation, consumed by analytics, CV and officers alike.

    Target is a product, a brand, or a whole manufacturer's range within a category.
    preferred_band: top | eye | middle | bottom | any (see domain.placement for band maths).
    """

    __tablename__ = "placement_rule"

    rule_set_id: Mapped[str] = mapped_column(ForeignKey("rule_set.id"), index=True)
    channel_id: Mapped[str | None] = mapped_column(ForeignKey("channel.id"))
    category_id: Mapped[str | None] = mapped_column(ForeignKey("category.id"))
    product_id: Mapped[str | None] = mapped_column(ForeignKey("product.id"))
    brand_id: Mapped[str | None] = mapped_column(ForeignKey("brand.id"))
    manufacturer_id: Mapped[str | None] = mapped_column(ForeignKey("manufacturer.id"))
    preferred_band: Mapped[str] = mapped_column(String(16), default="any")
    min_facings: Mapped[int] = mapped_column(Integer, default=1)
    min_share_of_shelf: Mapped[float | None] = mapped_column(Float)
    priority: Mapped[int] = mapped_column(Integer, default=2)
    promo_required: Mapped[bool] = mapped_column(Boolean, default=False)
    description: Mapped[str] = mapped_column(String(500))
