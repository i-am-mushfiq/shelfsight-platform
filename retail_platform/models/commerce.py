from __future__ import annotations

from datetime import date

from sqlalchemy import JSON, Date, Float, ForeignKey, Integer, Numeric, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .base import Base, Entity


class Order(Base, Entity):
    """Secondary sales: distributor → outlet. Contains own products only."""

    __tablename__ = "sales_order"
    __table_args__ = (UniqueConstraint("organization_id", "external_ref"),)

    outlet_id: Mapped[str] = mapped_column(ForeignKey("outlet.id"), index=True)
    user_id: Mapped[str | None] = mapped_column(ForeignKey("app_user.id"))
    distributor_id: Mapped[str | None] = mapped_column(ForeignKey("distributor.id"))
    visit_id: Mapped[str | None] = mapped_column(ForeignKey("visit.id"))
    order_date: Mapped[date] = mapped_column(Date, index=True)
    source: Mapped[str] = mapped_column(String(16), default="ingest")  # ingest | app
    external_ref: Mapped[str] = mapped_column(String(64))
    status: Mapped[str] = mapped_column(String(16), default="confirmed")

    items: Mapped[list[OrderItem]] = relationship(back_populates="order", cascade="all, delete-orphan")


class OrderItem(Base, Entity):
    __tablename__ = "sales_order_item"

    order_id: Mapped[str] = mapped_column(ForeignKey("sales_order.id"), index=True)
    product_id: Mapped[str] = mapped_column(ForeignKey("product.id"), index=True)
    quantity: Mapped[int] = mapped_column(Integer)
    unit_price: Mapped[float] = mapped_column(Numeric(12, 2))
    line_value: Mapped[float] = mapped_column(Numeric(14, 2))
    # Closed loop: what the platform suggested vs what was ordered.
    suggested_quantity: Mapped[int | None] = mapped_column(Integer)
    recommendation_id: Mapped[str | None] = mapped_column(ForeignKey("recommendation.id"))

    order: Mapped[Order] = relationship(back_populates="items")


class Promotion(Base, Entity):
    __tablename__ = "promotion"
    __table_args__ = (UniqueConstraint("organization_id", "code"),)

    code: Mapped[str] = mapped_column(String(32))
    name: Mapped[str] = mapped_column(String(200))
    mechanic: Mapped[str] = mapped_column(String(500))
    starts_on: Mapped[date] = mapped_column(Date)
    ends_on: Mapped[date] = mapped_column(Date)
    channel_id: Mapped[str | None] = mapped_column(ForeignKey("channel.id"))
    eligibility: Mapped[dict] = mapped_column(JSON, default=dict)


class PromotionProduct(Base, Entity):
    __tablename__ = "promotion_product"

    promotion_id: Mapped[str] = mapped_column(ForeignKey("promotion.id"), index=True)
    product_id: Mapped[str] = mapped_column(ForeignKey("product.id"), index=True)
    discount_pct: Mapped[float | None] = mapped_column(Float)
