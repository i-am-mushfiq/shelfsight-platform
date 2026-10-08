from __future__ import annotations

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel
from sqlalchemy import select

from .. import audit
from ..models import Organization, Territory, User
from ..security import Principal, hash_password, issue_token, verify_password
from .deps import DB, CurrentPrincipal

router = APIRouter(prefix="/v2/auth", tags=["auth"])
_DUMMY_HASH = hash_password("timing-equaliser")


class LoginRequest(BaseModel):
    employee_id: str
    password: str
    organization: str | None = None  # slug; required only when an employee id exists in several orgs


class UserOut(BaseModel):
    id: str
    employee_id: str
    name: str
    role: str
    territory: str | None
    organization: str
    data_origin: str
    preferred_language: str


class LoginResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_at: str
    user: UserOut


def _user_out(session, user: User) -> UserOut:  # type: ignore[no-untyped-def]
    org = session.get(Organization, user.organization_id)
    territory = session.get(Territory, user.territory_id) if user.territory_id else None
    return UserOut(id=user.id, employee_id=user.employee_id, name=user.name, role=user.role,
                   territory=territory.name if territory else None, organization=org.slug,
                   data_origin=org.data_origin, preferred_language=user.preferred_language)


@router.post("/login", response_model=LoginResponse)
def login(body: LoginRequest, session: DB) -> LoginResponse:
    query = select(User).where(User.employee_id == body.employee_id.strip().upper(), User.is_active.is_(True))
    if body.organization:
        query = query.join(Organization, Organization.id == User.organization_id).where(Organization.slug == body.organization)
    candidates = session.execute(query).scalars().all()
    user = candidates[0] if len(candidates) == 1 else None
    # Hash even for unknown users so response time does not reveal which employee ids exist.
    valid = verify_password(body.password, user.password_hash if user else _DUMMY_HASH)
    if user is None or not valid:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Employee ID or password is incorrect")
    token, expires = issue_token(user)
    audit.record(session, None, "auth.login", "app_user", user.id, organization_id=user.organization_id)
    session.commit()
    return LoginResponse(access_token=token, expires_at=expires.isoformat(), user=_user_out(session, user))


@router.get("/me", response_model=UserOut)
def me(principal: CurrentPrincipal, session: DB) -> UserOut:
    user = session.get(User, principal.user_id)
    assert user is not None
    return _user_out(session, user)


__all__ = ["router", "Principal"]
