"""AI models as versioned production dependencies, plus the DB-backed job queue."""

from __future__ import annotations

from datetime import datetime

from sqlalchemy import JSON, DateTime, ForeignKey, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .base import Base, Entity, utcnow


class Model(Base, Entity):
    __tablename__ = "model"
    __table_args__ = (UniqueConstraint("organization_id", "code"),)

    code: Mapped[str] = mapped_column(String(64))
    task: Mapped[str] = mapped_column(String(32))  # shelf_recognition | sku_recognition | ...
    description: Mapped[str | None] = mapped_column(String(1000))


class ModelVersion(Base, Entity):
    __tablename__ = "model_version"
    __table_args__ = (UniqueConstraint("model_id", "version"),)

    model_id: Mapped[str] = mapped_column(ForeignKey("model.id"), index=True)
    version: Mapped[str] = mapped_column(String(64))
    provider: Mapped[str] = mapped_column(String(64))
    artifact_sha256: Mapped[str | None] = mapped_column(String(64))
    config: Mapped[dict] = mapped_column(JSON, default=dict)
    # candidate | active | retired
    status: Mapped[str] = mapped_column(String(16), default="candidate")
    activated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    model: Mapped[Model] = relationship()


class EvaluationRun(Base, Entity):
    __tablename__ = "evaluation_run"

    model_version_id: Mapped[str] = mapped_column(ForeignKey("model_version.id"), index=True)
    dataset: Mapped[str] = mapped_column(String(200))
    dataset_sha256: Mapped[str] = mapped_column(String(64))
    metrics: Mapped[dict] = mapped_column(JSON, default=dict)
    per_class: Mapped[dict] = mapped_column(JSON, default=dict)
    slices: Mapped[dict] = mapped_column(JSON, default=dict)


class Job(Base, Entity):
    """Durable background work. Idempotent by (kind, dedupe_key)."""

    __tablename__ = "job"
    __table_args__ = (UniqueConstraint("organization_id", "kind", "dedupe_key"),)

    kind: Mapped[str] = mapped_column(String(32))
    dedupe_key: Mapped[str] = mapped_column(String(128))
    payload: Mapped[dict] = mapped_column(JSON, default=dict)
    # pending | running | done | failed
    status: Mapped[str] = mapped_column(String(16), default="pending", index=True)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    max_attempts: Mapped[int] = mapped_column(Integer, default=3)
    run_after: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    locked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    last_error: Mapped[str | None] = mapped_column(String(2000))
