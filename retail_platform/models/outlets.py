from __future__ import annotations

from datetime import date, datetime

from sqlalchemy import JSON, Boolean, Date, DateTime, Float, ForeignKey, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .base import Base, Entity, utcnow


class Territory(Base, Entity):
    """Sales geography tree: region › area › territory (levels are configurable labels)."""

    __tablename__ = "territory"
    __table_args__ = (UniqueConstraint("organization_id", "code"),)

    code: Mapped[str] = mapped_column(String(32))
    name: Mapped[str] = mapped_column(String(200))
    kind: Mapped[str] = mapped_column(String(32))
    parent_id: Mapped[str | None] = mapped_column(ForeignKey("territory.id"))
    path: Mapped[str] = mapped_column(String(500), index=True)


class Distributor(Base, Entity):
    __tablename__ = "distributor"
    __table_args__ = (UniqueConstraint("organization_id", "code"),)

    code: Mapped[str] = mapped_column(String(32))
    name: Mapped[str] = mapped_column(String(200))
    territory_id: Mapped[str | None] = mapped_column(ForeignKey("territory.id"))


class Channel(Base, Entity):
    """Configurable channel taxonomy (tree). Never hardcoded in application logic."""

    __tablename__ = "channel"
    __table_args__ = (UniqueConstraint("organization_id", "code"),)

    code: Mapped[str] = mapped_column(String(32))
    name: Mapped[str] = mapped_column(String(200))
    name_bn: Mapped[str | None] = mapped_column(String(200))
    parent_id: Mapped[str | None] = mapped_column(ForeignKey("channel.id"))
    path: Mapped[str] = mapped_column(String(500), index=True)
    description: Mapped[str | None] = mapped_column(String(500))
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)


class Outlet(Base, Entity):
    __tablename__ = "outlet"
    __table_args__ = (UniqueConstraint("organization_id", "code"),)

    code: Mapped[str] = mapped_column(String(32))
    name: Mapped[str] = mapped_column(String(200))
    name_bn: Mapped[str | None] = mapped_column(String(200))
    owner_name: Mapped[str | None] = mapped_column(String(200))
    phone: Mapped[str | None] = mapped_column(String(32))
    address: Mapped[str | None] = mapped_column(String(500))
    lat: Mapped[float | None] = mapped_column(Float)
    lng: Mapped[float | None] = mapped_column(Float)
    territory_id: Mapped[str] = mapped_column(ForeignKey("territory.id"), index=True)
    distributor_id: Mapped[str | None] = mapped_column(ForeignKey("distributor.id"))
    channel_id: Mapped[str] = mapped_column(ForeignKey("channel.id"), index=True)
    size_sqft: Mapped[float | None] = mapped_column(Float)
    shelf_meters: Mapped[float | None] = mapped_column(Float)
    footfall_estimate: Mapped[float | None] = mapped_column(Float)
    attributes: Mapped[dict] = mapped_column(JSON, default=dict)
    is_verified: Mapped[bool] = mapped_column(Boolean, default=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)

    territory: Mapped[Territory] = relationship()
    channel: Mapped[Channel] = relationship()


class OutletAssignment(Base, Entity):
    __tablename__ = "outlet_assignment"

    outlet_id: Mapped[str] = mapped_column(ForeignKey("outlet.id"), index=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("app_user.id"), index=True)
    effective_from: Mapped[date] = mapped_column(Date)
    effective_to: Mapped[date | None] = mapped_column(Date)


class ClassScheme(Base, Entity):
    """A versioned outlet-classification scheme, e.g. "Outlet Potential v1"."""

    __tablename__ = "class_scheme"
    __table_args__ = (UniqueConstraint("organization_id", "code", "version"),)

    code: Mapped[str] = mapped_column(String(32))
    name: Mapped[str] = mapped_column(String(200))
    version: Mapped[int] = mapped_column(default=1)
    status: Mapped[str] = mapped_column(String(16), default="active")
    description: Mapped[str | None] = mapped_column(String(1000))


class OutletClass(Base, Entity):
    """One class within a scheme. ``criteria`` is evaluated by the classification engine.

    criteria: [{"feature": "sales_percentile_in_channel", "op": ">=", "value": 0.8}, ...]
    Classes are evaluated in ``rank`` order; the first class whose criteria all hold wins.
    """

    __tablename__ = "outlet_class"

    scheme_id: Mapped[str] = mapped_column(ForeignKey("class_scheme.id"), index=True)
    code: Mapped[str] = mapped_column(String(32))
    label: Mapped[str] = mapped_column(String(200))
    rank: Mapped[int] = mapped_column()
    criteria: Mapped[list] = mapped_column(JSON, default=list)
    description: Mapped[str | None] = mapped_column(String(1000))


class OutletClassification(Base, Entity):
    """A classification *assessment*. History is kept; human assessments override rule/model ones."""

    __tablename__ = "outlet_classification"

    outlet_id: Mapped[str] = mapped_column(ForeignKey("outlet.id"), index=True)
    scheme_id: Mapped[str] = mapped_column(ForeignKey("class_scheme.id"))
    class_id: Mapped[str] = mapped_column(ForeignKey("outlet_class.id"))
    source: Mapped[str] = mapped_column(String(16))  # rule | model | human
    confidence: Mapped[float] = mapped_column(Float)
    evidence: Mapped[dict] = mapped_column(JSON, default=dict)
    generator_version: Mapped[str | None] = mapped_column(String(32))
    assessed_by_user_id: Mapped[str | None] = mapped_column(ForeignKey("app_user.id"))
    assessed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)

    outlet_class: Mapped[OutletClass] = relationship()
