"""Authentication, role-based permissions and row-level data scoping."""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta

import jwt
from sqlalchemy import Select, or_, select
from sqlalchemy.orm import Session

from .config import get_settings
from .models import Outlet, OutletAssignment, Role, Territory, User

# --- passwords (stdlib scrypt; no native dependency to build on field servers) -----------

_SCRYPT = {"n": 2**14, "r": 8, "p": 1}


def hash_password(password: str) -> str:
    salt = os.urandom(16)
    digest = hashlib.scrypt(password.encode(), salt=salt, dklen=32, **_SCRYPT)
    return "scrypt$" + base64.b64encode(salt).decode() + "$" + base64.b64encode(digest).decode()


def verify_password(password: str, stored: str) -> bool:
    try:
        scheme, salt_b64, digest_b64 = stored.split("$")
    except ValueError:
        return False
    if scheme != "scrypt":
        return False
    digest = hashlib.scrypt(
        password.encode(), salt=base64.b64decode(salt_b64), dklen=32, **_SCRYPT
    )
    return hmac.compare_digest(digest, base64.b64decode(digest_b64))


# --- tokens --------------------------------------------------------------------------------


def issue_token(user: User) -> tuple[str, datetime]:
    settings = get_settings()
    expires = datetime.now(UTC) + timedelta(minutes=settings.access_token_minutes)
    token = jwt.encode(
        {"sub": user.id, "org": user.organization_id, "role": user.role, "exp": expires},
        settings.jwt_secret,
        algorithm="HS256",
    )
    return token, expires


def decode_token(token: str) -> dict[str, object]:
    return jwt.decode(token, get_settings().jwt_secret, algorithms=["HS256"])


# --- permissions ---------------------------------------------------------------------------

PERMISSIONS: dict[str, set[str]] = {
    Role.SALES_OFFICER: {
        "outlet:read", "outlet:register", "catalog:read", "visit:write", "capture:write", "detection:correct",
        "recommendation:feedback", "order:write", "observation:write", "analytics:read",
    },
    Role.SUPERVISOR: {
        "outlet:read", "outlet:register", "catalog:read", "visit:write", "capture:write", "detection:correct",
        "recommendation:feedback", "order:write", "observation:write", "analytics:read",
        "classification:override", "team:read",
    },
    Role.BRAND_MANAGER: {
        "outlet:read", "catalog:read", "catalog:write", "analytics:read", "rules:write",
        "classification:override", "team:read",
    },
    Role.MANAGEMENT: {"outlet:read", "catalog:read", "analytics:read", "team:read"},
    Role.ADMIN: {
        "outlet:read", "outlet:write", "catalog:read", "catalog:write", "analytics:read",
        "rules:write", "classification:override", "team:read", "admin", "ml:write",
        "data:import",
    },
}


def has_permission(role: str, permission: str) -> bool:
    return permission in PERMISSIONS.get(role, set())


@dataclass(frozen=True, slots=True)
class Principal:
    user_id: str
    organization_id: str
    role: str
    territory_id: str | None
    data_origin: str

    def can(self, permission: str) -> bool:
        return has_permission(self.role, permission)


def scoped_outlets(session: Session, principal: Principal, today: date | None = None) -> Select:
    """Outlets this principal may see. Always tenant-filtered; officers see assignments only."""
    today = today or date.today()
    query = select(Outlet).where(Outlet.organization_id == principal.organization_id)
    if principal.role == Role.SALES_OFFICER:
        assigned = select(OutletAssignment.outlet_id).where(
            OutletAssignment.user_id == principal.user_id,
            OutletAssignment.effective_from <= today,
            or_(OutletAssignment.effective_to.is_(None), OutletAssignment.effective_to >= today),
        )
        query = query.where(Outlet.id.in_(assigned))
    elif principal.role == Role.SUPERVISOR:
        if principal.territory_id is None:
            return query.where(False)
        home = session.get(Territory, principal.territory_id)
        if home is None:
            return query.where(False)
        subtree = select(Territory.id).where(
            Territory.organization_id == principal.organization_id,
            Territory.path.startswith(home.path),
        )
        query = query.where(Outlet.territory_id.in_(subtree))
    return query


def distance_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    import math

    radius = 6_371_000.0
    d_lat = math.radians(lat2 - lat1)
    d_lng = math.radians(lng2 - lng1)
    a = math.sin(d_lat / 2) ** 2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(d_lng / 2) ** 2
    return 2 * radius * math.asin(math.sqrt(a))


def can_access_outlet(session: Session, principal: Principal, outlet_id: str) -> bool:
    query = scoped_outlets(session, principal).where(Outlet.id == outlet_id)
    return session.execute(query.limit(1)).first() is not None
