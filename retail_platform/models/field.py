"""Field execution and visual evidence: visits, captures, inferences, detections, corrections."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import (
    JSON,
    Boolean,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .base import Base, Entity, utcnow


class Visit(Base, Entity):
    __tablename__ = "visit"
    __table_args__ = (UniqueConstraint("organization_id", "client_visit_id"),)

    outlet_id: Mapped[str] = mapped_column(ForeignKey("outlet.id"), index=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("app_user.id"), index=True)
    # Generated on the device so offline retries are idempotent.
    client_visit_id: Mapped[str] = mapped_column(String(64))
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    lat: Mapped[float | None] = mapped_column(Float)
    lng: Mapped[float | None] = mapped_column(Float)
    distance_from_outlet_m: Mapped[float | None] = mapped_column(Float)
    status: Mapped[str] = mapped_column(String(16), default="open")  # open | submitted
    notes: Mapped[str | None] = mapped_column(String(2000))


class ShelfCapture(Base, Entity):
    __tablename__ = "shelf_capture"
    __table_args__ = (UniqueConstraint("organization_id", "client_capture_id"),)

    visit_id: Mapped[str] = mapped_column(ForeignKey("visit.id"), index=True)
    outlet_id: Mapped[str] = mapped_column(ForeignKey("outlet.id"), index=True)
    client_capture_id: Mapped[str] = mapped_column(String(64))
    area: Mapped[str | None] = mapped_column(String(100))
    category_id: Mapped[str | None] = mapped_column(ForeignKey("category.id"))
    blob_key: Mapped[str] = mapped_column(String(300))
    sha256: Mapped[str] = mapped_column(String(64), index=True)
    content_type: Mapped[str] = mapped_column(String(32))
    width: Mapped[int | None] = mapped_column(Integer)
    height: Mapped[int | None] = mapped_column(Integer)
    quality: Mapped[dict] = mapped_column(JSON, default=dict)
    quality_acceptable: Mapped[bool] = mapped_column(Boolean, default=True)
    duplicate_of_id: Mapped[str | None] = mapped_column(ForeignKey("shelf_capture.id"))
    captured_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    uploaded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    device: Mapped[dict] = mapped_column(JSON, default=dict)
    # uploaded | analysing | analysed | failed
    status: Mapped[str] = mapped_column(String(16), default="uploaded")


class Inference(Base, Entity):
    """One model run on one capture. Immutable once finished; reruns create new rows."""

    __tablename__ = "inference"

    capture_id: Mapped[str] = mapped_column(ForeignKey("shelf_capture.id"), index=True)
    model_version_id: Mapped[str] = mapped_column(ForeignKey("model_version.id"), index=True)
    status: Mapped[str] = mapped_column(String(16), default="running")  # running | succeeded | failed
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    latency_ms: Mapped[int | None] = mapped_column(Integer)
    cost_usd: Mapped[float | None] = mapped_column(Float)
    config: Mapped[dict] = mapped_column(JSON, default=dict)
    input_sha256: Mapped[str] = mapped_column(String(64))
    warnings: Mapped[list] = mapped_column(JSON, default=list)
    error: Mapped[str | None] = mapped_column(String(2000))
    annotated_blob_key: Mapped[str | None] = mapped_column(String(300))

    detections: Mapped[list[DetectedObject]] = relationship(back_populates="inference")


class DetectedObject(Base, Entity):
    """A detected facing. Prediction fields never change; ``final_*`` reflect human review."""

    __tablename__ = "detected_object"

    inference_id: Mapped[str] = mapped_column(ForeignKey("inference.id"), index=True)
    capture_id: Mapped[str] = mapped_column(ForeignKey("shelf_capture.id"), index=True)
    x: Mapped[float] = mapped_column(Float)
    y: Mapped[float] = mapped_column(Float)
    width: Mapped[float] = mapped_column(Float)
    height: Mapped[float] = mapped_column(Float)
    shelf_row: Mapped[int | None] = mapped_column(Integer)
    shelf_rows_total: Mapped[int | None] = mapped_column(Integer)
    # own | competitor | unknown
    predicted_label: Mapped[str] = mapped_column(String(16))
    predicted_product_id: Mapped[str | None] = mapped_column(ForeignKey("product.id"))
    predicted_manufacturer_id: Mapped[str | None] = mapped_column(ForeignKey("manufacturer.id"))
    confidence: Mapped[float] = mapped_column(Float)
    evidence: Mapped[dict] = mapped_column(JSON, default=dict)
    needs_review: Mapped[bool] = mapped_column(Boolean, default=False)
    # unverified | confirmed | corrected | rejected (not a product)
    verification: Mapped[str] = mapped_column(String(16), default="unverified")
    final_label: Mapped[str] = mapped_column(String(16))
    final_product_id: Mapped[str | None] = mapped_column(ForeignKey("product.id"))
    final_manufacturer_id: Mapped[str | None] = mapped_column(ForeignKey("manufacturer.id"))

    inference: Mapped[Inference] = relationship(back_populates="detections")


class RecognitionCorrection(Base, Entity):
    """Human feedback on a detection. This is labelled training data."""

    __tablename__ = "recognition_correction"

    detected_object_id: Mapped[str] = mapped_column(ForeignKey("detected_object.id"), index=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("app_user.id"))
    model_version_id: Mapped[str] = mapped_column(ForeignKey("model_version.id"))
    action: Mapped[str] = mapped_column(String(16))  # confirm | correct | reject
    previous_label: Mapped[str] = mapped_column(String(16))
    previous_product_id: Mapped[str | None] = mapped_column(String(32))
    new_label: Mapped[str] = mapped_column(String(16))
    new_product_id: Mapped[str | None] = mapped_column(ForeignKey("product.id"))
    new_manufacturer_id: Mapped[str | None] = mapped_column(ForeignKey("manufacturer.id"))
    reason: Mapped[str | None] = mapped_column(String(500))


class ShelfMeasurement(Base, Entity):
    """A computed shelf metric. Metric types are distinct and never conflated.

    metric: share_of_shelf | share_of_assortment | facings | presence
    basis: all (every detection) | verified (human-reviewed detections only)
    """

    __tablename__ = "shelf_measurement"

    visit_id: Mapped[str] = mapped_column(ForeignKey("visit.id"), index=True)
    outlet_id: Mapped[str] = mapped_column(ForeignKey("outlet.id"), index=True)
    metric: Mapped[str] = mapped_column(String(32))
    scope_type: Mapped[str] = mapped_column(String(16))  # manufacturer | brand | product | own
    scope_id: Mapped[str | None] = mapped_column(String(32))
    category_id: Mapped[str | None] = mapped_column(ForeignKey("category.id"))
    numerator: Mapped[float] = mapped_column(Float)
    denominator: Mapped[float] = mapped_column(Float)
    value: Mapped[float] = mapped_column(Float)
    basis: Mapped[str] = mapped_column(String(16))
    computed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    inputs: Mapped[dict] = mapped_column(JSON, default=dict)


class CompetitorObservation(Base, Entity):
    __tablename__ = "competitor_observation"

    outlet_id: Mapped[str] = mapped_column(ForeignKey("outlet.id"), index=True)
    visit_id: Mapped[str | None] = mapped_column(ForeignKey("visit.id"))
    user_id: Mapped[str | None] = mapped_column(ForeignKey("app_user.id"))
    manufacturer_id: Mapped[str] = mapped_column(ForeignKey("manufacturer.id"), index=True)
    brand_id: Mapped[str | None] = mapped_column(ForeignKey("brand.id"))
    product_id: Mapped[str | None] = mapped_column(ForeignKey("product.id"))
    # presence | price | promotion | display | note
    kind: Mapped[str] = mapped_column(String(16))
    observed_price: Mapped[float | None] = mapped_column(Float)
    facings: Mapped[int | None] = mapped_column(Integer)
    notes: Mapped[str | None] = mapped_column(String(1000))
    source: Mapped[str] = mapped_column(String(16), default="manual")  # manual | vision
    observed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
