from __future__ import annotations

import uuid
from datetime import UTC, datetime

from sqlalchemy import JSON, DateTime, ForeignKey, String
from sqlalchemy.orm import DeclarativeBase, Mapped, declared_attr, mapped_column


def new_id() -> str:
    return uuid.uuid4().hex


def utcnow() -> datetime:
    return datetime.now(UTC)


class Base(DeclarativeBase):
    type_annotation_map = {dict: JSON, list: JSON}


class IdMixin:
    id: Mapped[str] = mapped_column(String(32), primary_key=True, default=new_id)


class TimestampMixin:
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow
    )


class TenantMixin:
    """Every business row belongs to exactly one organization (tenant / business unit)."""

    @declared_attr
    def organization_id(cls) -> Mapped[str]:  # noqa: N805
        return mapped_column(String(32), ForeignKey("organization.id"), index=True)


class OriginMixin:
    """Marks rows as production or synthetic so demo data can never be mistaken for real."""

    data_origin: Mapped[str] = mapped_column(String(16), default="production")


class Entity(IdMixin, TenantMixin, OriginMixin, TimestampMixin):
    pass
