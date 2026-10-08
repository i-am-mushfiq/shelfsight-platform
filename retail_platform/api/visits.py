from __future__ import annotations

import json
from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from fastapi.responses import Response
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from .. import audit
from ..models import (
    Category,
    DetectedObject,
    Inference,
    ModelVersion,
    Outlet,
    ShelfCapture,
    ShelfMeasurement,
    Visit,
    utcnow,
)
from ..security import Principal, distance_m
from ..services import intelligence, loaders
from ..vision import pipeline
from .deps import DB, CurrentPrincipal, outlet_or_404, require
from .outlets import recommendation_out, serialize_intelligence

router = APIRouter(prefix="/v2", tags=["field"])

Writer = Annotated[Principal, Depends(require("visit:write"))]

GPS_WARNING_METERS = 150


class VisitIn(BaseModel):
    client_visit_id: str = Field(min_length=8, max_length=64)
    outlet_id: str
    lat: float | None = None
    lng: float | None = None
    started_at: datetime | None = None
    notes: str | None = Field(default=None, max_length=2000)


def _visit_out(visit: Visit) -> dict:
    return {
        "id": visit.id, "client_visit_id": visit.client_visit_id, "outlet_id": visit.outlet_id,
        "user_id": visit.user_id, "status": visit.status, "started_at": visit.started_at.isoformat(),
        "ended_at": visit.ended_at.isoformat() if visit.ended_at else None,
        "distance_from_outlet_m": visit.distance_from_outlet_m,
        "location_warning": (visit.distance_from_outlet_m or 0) > GPS_WARNING_METERS,
        "data_origin": visit.data_origin,
    }


@router.post("/visits", status_code=201)
def start_visit(body: VisitIn, principal: Writer, session: DB) -> dict:
    outlet = outlet_or_404(session, principal, body.outlet_id)
    existing = session.execute(select(Visit).where(Visit.organization_id == principal.organization_id,
                                                   Visit.client_visit_id == body.client_visit_id)).scalar_one_or_none()
    if existing is not None:
        if existing.outlet_id != outlet.id or existing.user_id != principal.user_id:
            raise HTTPException(status.HTTP_409_CONFLICT, "client_visit_id already used")
        return _visit_out(existing)
    distance = None
    if body.lat is not None and body.lng is not None and outlet.lat is not None and outlet.lng is not None:
        distance = round(distance_m(body.lat, body.lng, outlet.lat, outlet.lng), 1)
    visit = Visit(organization_id=principal.organization_id, data_origin=outlet.data_origin, outlet_id=outlet.id,
                  user_id=principal.user_id, client_visit_id=body.client_visit_id,
                  started_at=body.started_at or utcnow(), lat=body.lat, lng=body.lng,
                  distance_from_outlet_m=distance, notes=body.notes)
    session.add(visit)
    audit.record(session, principal, "visit.start", "visit", None, {"outlet_id": outlet.id, "distance_m": distance})
    try:
        session.commit()
    except IntegrityError:
        session.rollback()
        visit = session.execute(select(Visit).where(Visit.organization_id == principal.organization_id,
                                                    Visit.client_visit_id == body.client_visit_id)).scalar_one()
    return _visit_out(visit)


def _visit_or_404(session, principal: Principal, visit_id: str, write: bool = False) -> Visit:  # type: ignore[no-untyped-def]
    visit = session.get(Visit, visit_id)
    if visit is None or visit.organization_id != principal.organization_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Visit not found")
    outlet_or_404(session, principal, visit.outlet_id)
    if write and visit.user_id != principal.user_id:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Only the officer who started the visit can change it")
    return visit


def _capture_out(session, capture: ShelfCapture, include_detections: bool = False) -> dict:  # type: ignore[no-untyped-def]
    latest_id = pipeline.latest_inference_ids(session, [capture.id]).get(capture.id)
    inference = session.get(Inference, latest_id) if latest_id else None
    if inference is None:
        inference = session.execute(select(Inference).where(Inference.capture_id == capture.id)
                                    .order_by(Inference.started_at.desc()).limit(1)).scalar_one_or_none()
    out: dict = {
        "id": capture.id, "client_capture_id": capture.client_capture_id, "visit_id": capture.visit_id,
        "status": capture.status, "area": capture.area, "category_id": capture.category_id,
        "quality": capture.quality, "quality_acceptable": capture.quality_acceptable,
        "duplicate_of": capture.duplicate_of_id, "width": capture.width, "height": capture.height,
        "uploaded_at": capture.uploaded_at.isoformat(), "image_url": f"/v2/captures/{capture.id}/image",
        "inference": None, "data_origin": capture.data_origin,
    }
    if inference is not None:
        version = session.get(ModelVersion, inference.model_version_id)
        detections = session.execute(select(DetectedObject).where(DetectedObject.inference_id == inference.id)).scalars().all()
        out["inference"] = {
            "id": inference.id, "status": inference.status, "latency_ms": inference.latency_ms,
            "cost_usd": inference.cost_usd, "warnings": inference.warnings, "error": inference.error,
            "model": {"version_id": version.id, "version": version.version, "provider": version.provider} if version else None,
            "annotated_url": f"/v2/inferences/{inference.id}/annotated" if inference.annotated_blob_key else None,
            "detections_total": len(detections),
            "needs_review": sum(d.needs_review for d in detections),
        }
        if include_detections:
            out["detections"] = [_detection_out(d) for d in detections]
    return out


def _detection_out(d: DetectedObject) -> dict:
    return {
        "id": d.id, "box": {"x": d.x, "y": d.y, "width": d.width, "height": d.height},
        "shelf_row": d.shelf_row, "shelf_rows_total": d.shelf_rows_total,
        "predicted": {"label": d.predicted_label, "product_id": d.predicted_product_id,
                      "manufacturer_id": d.predicted_manufacturer_id, "confidence": d.confidence},
        "final": {"label": d.final_label, "product_id": d.final_product_id, "manufacturer_id": d.final_manufacturer_id},
        "needs_review": d.needs_review, "verification": d.verification, "evidence": d.evidence,
    }


@router.post("/visits/{visit_id}/captures")
async def upload_capture(
    visit_id: str,
    principal: Annotated[Principal, Depends(require("capture:write"))],
    session: DB,
    response: Response,
    image: UploadFile = File(...),
    client_capture_id: str = Form(..., min_length=8, max_length=64),
    area: str | None = Form(default=None, max_length=100),
    category_id: str | None = Form(default=None),
    captured_at: datetime | None = Form(default=None),
    device: str | None = Form(default=None, max_length=2000),
) -> dict:
    visit = _visit_or_404(session, principal, visit_id, write=True)
    if visit.status != "open":
        raise HTTPException(status.HTTP_409_CONFLICT, "Visit is already submitted")
    if category_id:
        category = session.get(Category, category_id)
        if category is None or category.organization_id != principal.organization_id:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "Unknown category")
    try:
        device_info = json.loads(device) if device else {}
    except json.JSONDecodeError:
        device_info = {"raw": device[:200] if device else None}
    data = await image.read(pipeline.get_settings().max_upload_bytes + 1)
    try:
        result = pipeline.ingest_capture(session, principal, visit, data, image.content_type, image.filename,
                                         client_capture_id, area, category_id, captured_at, device_info)
        session.commit()
    except pipeline.CaptureRejected as exc:
        session.rollback()
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(exc)) from exc
    except IntegrityError:
        # Concurrent retry of the same capture: return the winner.
        session.rollback()
        result = pipeline.ingest_capture(session, principal, visit, data, image.content_type, image.filename,
                                         client_capture_id, area, category_id, captured_at, device_info)
    response.status_code = status.HTTP_201_CREATED if result.created else status.HTTP_200_OK
    return {**_capture_out(session, result.capture), "replayed": not result.created}


@router.get("/visits")
def list_visits(principal: CurrentPrincipal, session: DB, limit: int = 50) -> list[dict]:
    """Recent visits: officers see their own; supervisors and above see visits to outlets in scope."""
    from ..security import scoped_outlets

    query = select(Visit, Outlet.name).join(Outlet, Outlet.id == Visit.outlet_id).where(
        Visit.organization_id == principal.organization_id,
        Visit.outlet_id.in_(scoped_outlets(session, principal).with_only_columns(Outlet.id)))
    if principal.role == "sales_officer":
        query = query.where(Visit.user_id == principal.user_id)
    rows = session.execute(query.order_by(Visit.started_at.desc()).limit(min(limit, 200))).all()
    visit_ids = [v.id for v, _ in rows]
    shares: dict[str, dict] = {}
    for m in session.execute(select(ShelfMeasurement).where(ShelfMeasurement.visit_id.in_(visit_ids),
                                                            ShelfMeasurement.metric == "share_of_shelf",
                                                            ShelfMeasurement.scope_type == "own")).scalars():
        shares.setdefault(m.visit_id, {})[m.basis] = {"value": m.value, "facings": m.denominator,
                                                      "range": m.inputs.get("range")}
    counts: dict[str, int] = {}
    for capture_visit in session.execute(select(ShelfCapture.visit_id).where(ShelfCapture.visit_id.in_(visit_ids))).scalars():
        counts[capture_visit] = counts.get(capture_visit, 0) + 1
    return [{**_visit_out(v), "outlet_name": name, "photos": counts.get(v.id, 0),
             "share_of_shelf": shares.get(v.id, {})} for v, name in rows]


@router.get("/visits/{visit_id}")
def get_visit(visit_id: str, principal: CurrentPrincipal, session: DB) -> dict:
    visit = _visit_or_404(session, principal, visit_id)
    captures = session.execute(select(ShelfCapture).where(ShelfCapture.visit_id == visit.id)
                               .order_by(ShelfCapture.uploaded_at)).scalars().all()
    measurements = session.execute(select(ShelfMeasurement).where(ShelfMeasurement.visit_id == visit.id,
                                                                  ShelfMeasurement.scope_type == "own")).scalars().all()
    return {**_visit_out(visit), "captures": [_capture_out(session, c) for c in captures],
            "measurements": [{"metric": m.metric, "basis": m.basis, "value": m.value, "numerator": m.numerator,
                              "denominator": m.denominator, "range": m.inputs.get("range"),
                              "unknown_facings": m.inputs.get("unknown_facings"),
                              "model_versions": m.inputs.get("model_versions")} for m in measurements]}


def _capture_or_404(session, principal: Principal, capture_id: str) -> ShelfCapture:  # type: ignore[no-untyped-def]
    capture = session.get(ShelfCapture, capture_id)
    if capture is None or capture.organization_id != principal.organization_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Capture not found")
    outlet_or_404(session, principal, capture.outlet_id)
    return capture


@router.get("/captures/{capture_id}")
def get_capture(capture_id: str, principal: CurrentPrincipal, session: DB) -> dict:
    return _capture_out(session, _capture_or_404(session, principal, capture_id), include_detections=True)


@router.get("/captures/{capture_id}/image")
def capture_image(capture_id: str, principal: CurrentPrincipal, session: DB) -> Response:
    capture = _capture_or_404(session, principal, capture_id)
    return Response(pipeline.blob_store().get(capture.blob_key), media_type=capture.content_type,
                    headers={"Cache-Control": "private, max-age=86400"})


@router.get("/inferences/{inference_id}/annotated")
def annotated_image(inference_id: str, principal: CurrentPrincipal, session: DB) -> Response:
    inference = session.get(Inference, inference_id)
    if inference is None or inference.organization_id != principal.organization_id or not inference.annotated_blob_key:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Annotated image not found")
    _capture_or_404(session, principal, inference.capture_id)
    return Response(pipeline.blob_store().get(inference.annotated_blob_key), media_type="image/jpeg",
                    headers={"Cache-Control": "private, max-age=86400"})


class ReviewIn(BaseModel):
    action: str = Field(pattern="^(confirm|correct|reject)$")
    label: str | None = Field(default=None, pattern="^(own|competitor|unknown)$")
    product_id: str | None = None
    reason: str | None = Field(default=None, max_length=500)


@router.post("/detections/{detection_id}/review")
def review_detection(detection_id: str, body: ReviewIn, session: DB,
                     principal: Annotated[Principal, Depends(require("detection:correct"))]) -> dict:
    detection = session.get(DetectedObject, detection_id)
    if detection is None or detection.organization_id != principal.organization_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Detection not found")
    _capture_or_404(session, principal, detection.capture_id)
    try:
        correction = pipeline.review_detection(session, principal, detection, body.action, body.label,
                                               body.product_id, body.reason)
    except ValueError as exc:
        session.rollback()
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(exc)) from exc
    session.commit()
    return {"correction_id": correction.id, **_detection_out(detection)}


@router.post("/visits/{visit_id}/submit")
def submit_visit(visit_id: str, principal: Writer, session: DB) -> dict:
    """Close the visit and refresh outlet intelligence with its verified shelf evidence."""
    visit = _visit_or_404(session, principal, visit_id, write=True)
    pending = session.execute(select(ShelfCapture.id).where(ShelfCapture.visit_id == visit.id,
                                                            ShelfCapture.status.in_(("uploaded", "analysing")))).first()
    if pending:
        raise HTTPException(status.HTTP_409_CONFLICT, "Some photos are still being analysed")
    if visit.status == "open":
        visit.status = "submitted"
        visit.ended_at = utcnow()
        audit.record(session, principal, "visit.submit", "visit", visit.id)
    intel = intelligence.analyze(session, principal.organization_id, visit.outlet_id)
    recs = intelligence.persist(session, principal.organization_id, intel, principal.data_origin, visit.id)
    session.commit()
    products = loaders.load_products(session, principal.organization_id)
    return {"visit": _visit_out(visit), "intelligence": serialize_intelligence(intel, recs, products, principal.data_origin)}


__all__ = ["router", "recommendation_out", "Outlet"]
