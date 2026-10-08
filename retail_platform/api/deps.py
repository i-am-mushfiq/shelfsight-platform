from __future__ import annotations

from collections.abc import Callable, Iterator
from typing import Annotated

import jwt
from fastapi import Depends, Header, HTTPException, Response, status
from sqlalchemy.orm import Session

from ..db import session_factory
from ..models import Organization, Outlet, User
from ..security import Principal, can_access_outlet, decode_token


def get_db() -> Iterator[Session]:
    session = session_factory()()
    try:
        yield session
    finally:
        session.close()


DB = Annotated[Session, Depends(get_db)]


def get_principal(
    session: DB,
    response: Response,
    authorization: Annotated[str | None, Header()] = None,
) -> Principal:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Missing bearer token",
                            headers={"WWW-Authenticate": "Bearer"})
    try:
        claims = decode_token(authorization.split(" ", 1)[1])
    except jwt.PyJWTError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid or expired token",
                            headers={"WWW-Authenticate": "Bearer"}) from exc
    user = session.get(User, str(claims["sub"]))
    if user is None or not user.is_active or user.organization_id != claims.get("org"):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "User is not active")
    org = session.get(Organization, user.organization_id)
    assert org is not None
    # Every response says whether it is built from synthetic data.
    response.headers["X-Data-Origin"] = org.data_origin
    return Principal(user_id=user.id, organization_id=user.organization_id, role=user.role,
                     territory_id=user.territory_id, data_origin=org.data_origin)


CurrentPrincipal = Annotated[Principal, Depends(get_principal)]


def require(permission: str) -> Callable[[Principal], Principal]:
    def check(principal: CurrentPrincipal) -> Principal:
        if not principal.can(permission):
            raise HTTPException(status.HTTP_403_FORBIDDEN, f"Missing permission: {permission}")
        return principal
    return check


def outlet_or_404(session: Session, principal: Principal, outlet_id: str) -> Outlet:
    outlet = session.get(Outlet, outlet_id)
    # Same 404 for "does not exist" and "not yours": no existence leak across scopes or tenants.
    if outlet is None or outlet.organization_id != principal.organization_id or not can_access_outlet(session, principal, outlet_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Outlet not found")
    return outlet
