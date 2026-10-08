from __future__ import annotations

from datetime import datetime

from sqlalchemy import JSON, Boolean, DateTime, ForeignKey, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from .base import Base, Entity, IdMixin, TimestampMixin, utcnow


class Organization(Base, IdMixin, TimestampMixin):
    __tablename__ = "organization"

    slug: Mapped[str] = mapped_column(String(64), unique=True)
    name: Mapped[str] = mapped_column(String(200))
    data_origin: Mapped[str] = mapped_column(String(16), default="production")


class Role:
    SALES_OFFICER = "sales_officer"
    SUPERVISOR = "supervisor"
    BRAND_MANAGER = "brand_manager"
    MANAGEMENT = "management"
    ADMIN = "admin"
    ALL = (SALES_OFFICER, SUPERVISOR, BRAND_MANAGER, MANAGEMENT, ADMIN)


class User(Base, Entity):
    __tablename__ = "app_user"
    __table_args__ = (UniqueConstraint("organization_id", "employee_id"),)

    employee_id: Mapped[str] = mapped_column(String(32))
    name: Mapped[str] = mapped_column(String(200))
    role: Mapped[str] = mapped_column(String(32))
    password_hash: Mapped[str] = mapped_column(String(255))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    # Home territory: supervisors see this subtree; officers are scoped by assignment.
    territory_id: Mapped[str | None] = mapped_column(ForeignKey("territory.id"))
    supervisor_id: Mapped[str | None] = mapped_column(ForeignKey("app_user.id"))
    preferred_language: Mapped[str] = mapped_column(String(8), default="bn")


class AuditLog(Base, IdMixin):
    __tablename__ = "audit_log"

    organization_id: Mapped[str] = mapped_column(String(32), index=True)
    user_id: Mapped[str | None] = mapped_column(String(32))
    action: Mapped[str] = mapped_column(String(64))
    entity_type: Mapped[str] = mapped_column(String(64))
    entity_id: Mapped[str | None] = mapped_column(String(64))
    changes: Mapped[dict] = mapped_column(JSON, default=dict)
    request_id: Mapped[str | None] = mapped_column(String(64))
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)
