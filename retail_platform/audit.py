from __future__ import annotations

from sqlalchemy.orm import Session

from .models import AuditLog
from .observability import request_id_var
from .security import Principal


def record(
    session: Session,
    principal: Principal | None,
    action: str,
    entity_type: str,
    entity_id: str | None,
    changes: dict | None = None,
    organization_id: str | None = None,
) -> None:
    """Append an audit entry in the caller's transaction (committed with the change itself)."""
    session.add(
        AuditLog(
            organization_id=organization_id or (principal.organization_id if principal else ""),
            user_id=principal.user_id if principal else None,
            action=action,
            entity_type=entity_type,
            entity_id=entity_id,
            changes=changes or {},
            request_id=request_id_var.get(),
        )
    )
