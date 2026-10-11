"""Orders: the shelf-aware suggestion, orders placed from the app, the automatic order a
submitted visit creates, and changes to them while they are still editable.

Every change is audited and keeps the original suggested quantity next to the final one,
so suggestion → final order → sell-in can be compared later.
"""

from __future__ import annotations

from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from .. import audit
from ..models import Order, OrderItem, Recommendation, Role, Visit
from ..security import Principal
from ..services import loaders, ordering
from .deps import DB, outlet_or_404, require

router = APIRouter(prefix="/v2", tags=["orders"])

Reader = Annotated[Principal, Depends(require("outlet:read"))]
Writer = Annotated[Principal, Depends(require("order:write"))]


@router.get("/outlets/{outlet_id}/suggested-order")
def suggested_order(outlet_id: str, principal: Reader, session: DB, visit_id: str | None = None) -> dict:
    """Suggestion from history, recommendations and the shelf of ``visit_id`` (default: the latest recent audit)."""
    outlet_or_404(session, principal, outlet_id)
    if visit_id:
        visit = session.get(Visit, visit_id)
        if visit is None or visit.outlet_id != outlet_id:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Visit not found")
    suggestion = ordering.build_suggestion(session, principal.organization_id, outlet_id, visit_id=visit_id)
    return ordering.suggestion_out(suggestion, principal.data_origin)


class OrderLineIn(BaseModel):
    product_id: str
    quantity: int = Field(ge=1, le=100000)
    suggested_quantity: int | None = Field(default=None, ge=0)
    recommendation_id: str | None = None
    sources: list[dict] | None = None


class OrderIn(BaseModel):
    client_order_id: str = Field(min_length=8, max_length=64)
    visit_id: str | None = None
    lines: list[OrderLineIn] = Field(min_length=1)


def _items(session, principal: Principal, outlet_id: str, lines: list[OrderLineIn],  # type: ignore[no-untyped-def]
           previous: dict[str, OrderItem] | None = None) -> list[OrderItem]:
    products = loaders.load_products(session, principal.organization_id)
    previous = previous or {}
    seen: set[str] = set()
    items = []
    for line in lines:
        if line.product_id in seen:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"Product {line.product_id} appears twice")
        seen.add(line.product_id)
        product = products.get(line.product_id)
        if product is None or not product.is_own or not product.is_active:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"Product {line.product_id} cannot be ordered")
        if line.recommendation_id:
            rec = session.get(Recommendation, line.recommendation_id)
            if rec is None or rec.outlet_id != outlet_id:
                raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Recommendation does not belong to this outlet")
        if product.trade_price is None:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, f"No trade price configured for {product.sku}")
        before = previous.get(product.id)
        price = product.trade_price if before is None else float(before.unit_price)
        items.append(OrderItem(
            organization_id=principal.organization_id, data_origin=principal.data_origin, product_id=product.id,
            quantity=line.quantity, unit_price=round(price, 2), line_value=round(price * line.quantity, 2),
            # The original suggestion survives edits; it is what the closed loop measures against.
            suggested_quantity=before.suggested_quantity if before else line.suggested_quantity,
            recommendation_id=(before.recommendation_id if before else None) or line.recommendation_id,
            sources=before.sources if before else line.sources,
        ))
    return items


@router.post("/outlets/{outlet_id}/orders", status_code=201)
def create_order(outlet_id: str, body: OrderIn, session: DB, principal: Writer) -> dict:
    outlet = outlet_or_404(session, principal, outlet_id)
    ref = f"APP-{body.client_order_id}"
    existing = session.execute(select(Order).where(Order.organization_id == principal.organization_id,
                                                   Order.external_ref == ref)).scalar_one_or_none()
    if existing is not None:
        return {"id": existing.id, "status": existing.status, "replayed": True}
    if body.visit_id:
        visit = session.get(Visit, body.visit_id)
        if visit is None or visit.outlet_id != outlet.id:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Visit does not belong to this outlet")
    order = Order(organization_id=principal.organization_id, data_origin=principal.data_origin, outlet_id=outlet.id,
                  user_id=principal.user_id, distributor_id=outlet.distributor_id, visit_id=body.visit_id,
                  order_date=date.today(), source="app", external_ref=ref, status="confirmed",
                  meta={"generator_version": None})
    order.items.extend(_items(session, principal, outlet.id, body.lines))
    session.add(order)
    audit.record(session, principal, "order.create", "sales_order", None,
                 {"outlet_id": outlet.id, "lines": len(body.lines), "external_ref": ref})
    try:
        session.commit()
    except IntegrityError:
        session.rollback()
        existing = session.execute(select(Order).where(Order.organization_id == principal.organization_id,
                                                       Order.external_ref == ref)).scalar_one()
        return {"id": existing.id, "status": existing.status, "replayed": True}
    return {"id": order.id, "status": order.status, "replayed": False,
            "value": round(sum(float(i.line_value) for i in order.items), 2)}


@router.get("/outlets/{outlet_id}/orders")
def list_orders(outlet_id: str, principal: Reader, session: DB, limit: int = Query(20, ge=1, le=200)) -> list[dict]:
    outlet_or_404(session, principal, outlet_id)
    orders = session.execute(select(Order).where(Order.outlet_id == outlet_id)
                             .order_by(Order.order_date.desc(), Order.created_at.desc()).limit(limit)).scalars().all()
    products = loaders.load_products(session, principal.organization_id)
    return [ordering.order_out(o, products) for o in orders]


def _order_or_404(session, principal: Principal, order_id: str) -> Order:  # type: ignore[no-untyped-def]
    order = session.get(Order, order_id)
    if order is None or order.organization_id != principal.organization_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Order not found")
    outlet_or_404(session, principal, order.outlet_id)
    return order


def _editable_or_409(principal: Principal, order: Order) -> None:
    if principal.role == Role.SALES_OFFICER and order.user_id != principal.user_id:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Only the officer who placed the order can change it")
    if not ordering.editable(order):
        raise HTTPException(status.HTTP_409_CONFLICT,
                            f"Order can no longer be changed ({order.source}, {order.status}, "
                            f"edit window {ordering.EDIT_WINDOW_HOURS} h)")


@router.get("/orders/{order_id}")
def get_order(order_id: str, principal: Reader, session: DB) -> dict:
    order = _order_or_404(session, principal, order_id)
    return ordering.order_out(order, loaders.load_products(session, principal.organization_id))


class OrderUpdateIn(BaseModel):
    lines: list[OrderLineIn] = Field(min_length=1)
    note: str | None = Field(default=None, max_length=500)


@router.put("/orders/{order_id}")
def update_order(order_id: str, body: OrderUpdateIn, principal: Writer, session: DB) -> dict:
    """Replace the order's lines. Suggested quantities and their reasons are kept per product."""
    order = _order_or_404(session, principal, order_id)
    _editable_or_409(principal, order)
    previous = {item.product_id: item for item in order.items}
    before = {pid: item.quantity for pid, item in previous.items()}
    new_items = _items(session, principal, order.outlet_id, body.lines, previous)
    order.items.clear()
    session.flush()
    order.items.extend(new_items)
    order.meta = {**(order.meta or {}), "edited": True, "edit_note": body.note}
    audit.record(session, principal, "order.update", "sales_order", order.id,
                 {"before": before, "after": {i.product_id: i.quantity for i in new_items}, "note": body.note})
    session.commit()
    return ordering.order_out(order, loaders.load_products(session, principal.organization_id))


@router.post("/orders/{order_id}/confirm")
def confirm_order(order_id: str, principal: Writer, session: DB) -> dict:
    order = _order_or_404(session, principal, order_id)
    if order.status == "confirmed":
        return ordering.order_out(order, loaders.load_products(session, principal.organization_id))
    _editable_or_409(principal, order)
    order.status = "confirmed"
    audit.record(session, principal, "order.confirm", "sales_order", order.id, {"source": order.source})
    session.commit()
    return ordering.order_out(order, loaders.load_products(session, principal.organization_id))


class CancelIn(BaseModel):
    reason: str = Field(min_length=3, max_length=500)


@router.post("/orders/{order_id}/cancel")
def cancel_order(order_id: str, body: CancelIn, principal: Writer, session: DB) -> dict:
    order = _order_or_404(session, principal, order_id)
    if order.status == "cancelled":
        return ordering.order_out(order, loaders.load_products(session, principal.organization_id))
    _editable_or_409(principal, order)
    previous = order.status
    order.status = "cancelled"
    order.meta = {**(order.meta or {}), "cancel_reason": body.reason, "cancelled_by": principal.user_id}
    audit.record(session, principal, "order.cancel", "sales_order", order.id, {"from": previous, "reason": body.reason})
    session.commit()
    return ordering.order_out(order, loaders.load_products(session, principal.organization_id))
