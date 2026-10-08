from __future__ import annotations

from datetime import datetime

from sqlalchemy import JSON, DateTime, Float, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from .base import Base, Entity, utcnow


class OutletScore(Base, Entity):
    """One dimension of outlet intelligence. Dimensions are never collapsed at storage time."""

    __tablename__ = "outlet_score"

    outlet_id: Mapped[str] = mapped_column(ForeignKey("outlet.id"), index=True)
    dimension: Mapped[str] = mapped_column(String(32))
    # None when there is not enough data to score honestly.
    value: Mapped[float | None] = mapped_column(Float)
    inputs: Mapped[dict] = mapped_column(JSON, default=dict)
    generator_version: Mapped[str] = mapped_column(String(32))
    computed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Recommendation(Base, Entity):
    __tablename__ = "recommendation"

    outlet_id: Mapped[str] = mapped_column(ForeignKey("outlet.id"), index=True)
    visit_id: Mapped[str | None] = mapped_column(ForeignKey("visit.id"))
    # add_sku | increase_volume | fix_placement | increase_facings | competitor_response | rebalance_mix
    type: Mapped[str] = mapped_column(String(32))
    product_id: Mapped[str | None] = mapped_column(ForeignKey("product.id"))
    action: Mapped[str] = mapped_column(String(500))
    reason: Mapped[str] = mapped_column(String(1000))
    evidence: Mapped[dict] = mapped_column(JSON, default=dict)
    expected_impact: Mapped[dict] = mapped_column(JSON, default=dict)
    suggested_quantity: Mapped[int | None] = mapped_column(Integer)
    confidence: Mapped[float] = mapped_column(Float)
    priority: Mapped[int] = mapped_column(Integer)  # 1 = highest
    source: Mapped[str] = mapped_column(String(64))
    generator_version: Mapped[str] = mapped_column(String(32))
    # open | accepted | modified | rejected | superseded
    status: Mapped[str] = mapped_column(String(16), default="open")
    dedupe_key: Mapped[str] = mapped_column(String(200), index=True)


class RecommendationFeedback(Base, Entity):
    __tablename__ = "recommendation_feedback"

    recommendation_id: Mapped[str] = mapped_column(ForeignKey("recommendation.id"), index=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("app_user.id"))
    decision: Mapped[str] = mapped_column(String(16))  # accepted | modified | rejected
    modified_quantity: Mapped[int | None] = mapped_column(Integer)
    note: Mapped[str | None] = mapped_column(String(1000))
