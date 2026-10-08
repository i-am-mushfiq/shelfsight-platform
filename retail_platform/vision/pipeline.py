"""Capture → inference → detections → review → measurements.

Invariants:
  * uploads are idempotent by client_capture_id; byte-identical re-uploads in the same
    visit are flagged as duplicates and not analysed twice;
  * every inference row names its model version and is never mutated after finishing
    (reanalysis creates a new inference);
  * prediction fields on a detection never change; human review writes a correction row
    and updates the ``final_*`` fields;
  * measurements are derived data and are recomputed from detections on every change.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from datetime import datetime

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from .. import audit
from ..config import get_settings
from ..domain import shelf
from ..domain.records import Facing
from ..jobs import enqueue, handler
from ..models import (
    Brand,
    Category,
    DetectedObject,
    Inference,
    Job,
    Manufacturer,
    Product,
    RecognitionCorrection,
    ShelfCapture,
    ShelfMeasurement,
    Visit,
    utcnow,
)
from ..observability import CORRECTIONS, INFERENCE_COST, INFERENCE_LATENCY, INFERENCES, UPLOADS
from ..security import Principal
from ..storage import LocalBlobStore, artifact_key, capture_key, sha256
from .base import CatalogEntry
from .opencv_baseline import image_quality
from .registry import ensure_model_version, get_provider

log = logging.getLogger(__name__)

ANALYZE_JOB = "analyze_capture"
_CONTENT_TYPES = {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp"}


def blob_store() -> LocalBlobStore:
    return LocalBlobStore(get_settings().blob_directory)


class CaptureRejected(ValueError):
    pass


@dataclass(slots=True)
class IngestResult:
    capture: ShelfCapture
    created: bool
    duplicate: bool


def ingest_capture(
    session: Session,
    principal: Principal,
    visit: Visit,
    data: bytes,
    content_type: str | None,
    filename: str | None,
    client_capture_id: str,
    area: str | None,
    category_id: str | None,
    captured_at: datetime | None,
    device: dict,
) -> IngestResult:
    existing = session.execute(
        select(ShelfCapture).where(ShelfCapture.organization_id == principal.organization_id,
                                   ShelfCapture.client_capture_id == client_capture_id)
    ).scalar_one_or_none()
    if existing is not None:
        if existing.visit_id != visit.id:
            raise CaptureRejected("client_capture_id already used for another visit")
        UPLOADS.labels("idempotent_replay").inc()
        return IngestResult(existing, created=False, duplicate=existing.duplicate_of_id is not None)

    if len(data) > get_settings().max_upload_bytes:
        raise CaptureRejected("Image is larger than the upload limit")
    extension = _CONTENT_TYPES.get(content_type or "")
    if extension is None and filename:
        suffix = filename.lower().rsplit(".", 1)[-1]
        extension = {"jpg": "jpg", "jpeg": "jpg", "png": "png", "webp": "webp"}.get(suffix)
    if extension is None:
        raise CaptureRejected("Unsupported image type; use JPEG, PNG or WebP")
    try:
        quality = image_quality(data)
    except ValueError as exc:
        raise CaptureRejected(str(exc)) from exc

    digest = sha256(data)
    duplicate_of = session.execute(
        select(ShelfCapture.id).where(ShelfCapture.visit_id == visit.id, ShelfCapture.sha256 == digest).limit(1)
    ).scalar_one_or_none()
    key = capture_key(principal.organization_id, digest, extension)
    store = blob_store()
    if not store.exists(key):
        store.put(key, data)
    capture = ShelfCapture(
        organization_id=principal.organization_id, data_origin=visit.data_origin,
        visit_id=visit.id, outlet_id=visit.outlet_id, client_capture_id=client_capture_id,
        area=area, category_id=category_id, blob_key=key, sha256=digest,
        content_type=f"image/{'jpeg' if extension == 'jpg' else extension}",
        width=quality["width"], height=quality["height"], quality=quality,
        quality_acceptable=quality["acceptable"], duplicate_of_id=duplicate_of,
        captured_at=captured_at, device=device,
        status="duplicate" if duplicate_of else "uploaded",
    )
    session.add(capture)
    session.flush()
    if duplicate_of is None:
        enqueue(session, principal.organization_id, ANALYZE_JOB, capture.id, {"capture_id": capture.id},
                data_origin=visit.data_origin)
    audit.record(session, principal, "capture.upload", "shelf_capture", capture.id,
                 {"visit_id": visit.id, "sha256": digest, "duplicate_of": duplicate_of,
                  "quality_acceptable": quality["acceptable"]})
    UPLOADS.labels("duplicate" if duplicate_of else "accepted").inc()
    return IngestResult(capture, created=True, duplicate=duplicate_of is not None)


def catalog_for(session: Session, organization_id: str, category_id: str | None) -> tuple[list[CatalogEntry], str | None]:
    query = (
        select(Product, Brand, Manufacturer, Category)
        .join(Brand, Product.brand_id == Brand.id)
        .join(Manufacturer, Product.manufacturer_id == Manufacturer.id)
        .join(Category, Product.category_id == Category.id)
        .where(Product.organization_id == organization_id, Product.is_active.is_(True))
    )
    if category_id:
        category = session.get(Category, category_id)
        if category is not None:
            query = query.where(Category.path.startswith(category.path))
    entries = []
    own_id = None
    for product, brand, manufacturer, category in session.execute(query):
        if manufacturer.is_own:
            own_id = manufacturer.id
        pack = f"{product.pack_size:g}{product.pack_unit}" if product.pack_size and product.pack_unit else None
        entries.append(CatalogEntry(product.id, product.sku, product.name, brand.name, manufacturer.id,
                                    manufacturer.name, manufacturer.is_own, category.name, pack))
    if own_id is None:
        own_id = session.execute(
            select(Manufacturer.id).where(Manufacturer.organization_id == organization_id, Manufacturer.is_own.is_(True))
        ).scalars().first()
    return entries, own_id


def run_inference(session: Session, capture: ShelfCapture) -> Inference:
    settings = get_settings()
    provider = get_provider(settings)
    version = ensure_model_version(session, capture.organization_id, provider)
    inference = Inference(organization_id=capture.organization_id, data_origin=capture.data_origin,
                          capture_id=capture.id, model_version_id=version.id, config=provider.config,
                          input_sha256=capture.sha256, status="running")
    session.add(inference)
    capture.status = "analysing"
    catalog, own_manufacturer = catalog_for(session, capture.organization_id, capture.category_id)
    # Commit before the (possibly slow, remote) provider call so no write lock is held during it,
    # and so a failed run stays recorded even when the caller rolls back.
    session.commit()

    started = time.perf_counter()
    try:
        result = provider.analyze(blob_store().get(capture.blob_key), catalog, own_manufacturer)
    except Exception as exc:
        inference.status = "failed"
        inference.error = str(exc)[:2000]
        inference.finished_at = utcnow()
        inference.latency_ms = int((time.perf_counter() - started) * 1000)
        capture.status = "failed"
        INFERENCES.labels(provider.provider, "failed").inc()
        session.commit()
        raise
    elapsed = time.perf_counter() - started

    rows, total_rows = shelf.assign_shelf_rows([d.y + d.height / 2 for d in result.detections],
                                               [d.height for d in result.detections])
    threshold = settings.review_confidence_threshold
    for detection, row in zip(result.detections, rows):
        needs_review = detection.label == "unknown" or detection.confidence < threshold
        session.add(DetectedObject(
            organization_id=capture.organization_id, data_origin=capture.data_origin,
            inference_id=inference.id, capture_id=capture.id,
            x=detection.x, y=detection.y, width=detection.width, height=detection.height,
            shelf_row=row, shelf_rows_total=total_rows,
            predicted_label=detection.label, predicted_product_id=detection.product_id,
            predicted_manufacturer_id=detection.manufacturer_id, confidence=round(detection.confidence, 4),
            evidence=detection.evidence, needs_review=needs_review,
            final_label=detection.label, final_product_id=detection.product_id,
            final_manufacturer_id=detection.manufacturer_id,
        ))
    if result.annotated_jpeg:
        key = artifact_key(capture.organization_id, inference.id)
        blob_store().put(key, result.annotated_jpeg)
        inference.annotated_blob_key = key
    inference.status = "succeeded"
    inference.finished_at = utcnow()
    inference.latency_ms = int(elapsed * 1000)
    inference.cost_usd = result.cost_usd
    inference.warnings = result.warnings
    capture.status = "analysed"
    session.flush()
    INFERENCES.labels(provider.provider, "succeeded").inc()
    INFERENCE_LATENCY.labels(provider.provider).observe(elapsed)
    if result.cost_usd:
        INFERENCE_COST.labels(provider.provider).inc(result.cost_usd)
    recompute_visit_measurements(session, capture.visit_id)
    return inference


@handler(ANALYZE_JOB)
def _analyze_job(session: Session, job: Job) -> None:
    capture = session.get(ShelfCapture, job.payload["capture_id"])
    if capture is None or capture.status == "analysed":
        return
    run_inference(session, capture)


def latest_inference_ids(session: Session, capture_ids: list[str]) -> dict[str, str]:
    """Most recent succeeded inference per capture."""
    result: dict[str, str] = {}
    if not capture_ids:
        return result
    rows = session.execute(
        select(Inference.capture_id, Inference.id, Inference.finished_at)
        .where(Inference.capture_id.in_(capture_ids), Inference.status == "succeeded")
        .order_by(Inference.finished_at)
    )
    for capture_id, inference_id, _ in rows:
        result[capture_id] = inference_id
    return result


def visit_facings(session: Session, visit_id: str) -> tuple[list[Facing], list[str]]:
    captures = session.execute(
        select(ShelfCapture).where(ShelfCapture.visit_id == visit_id, ShelfCapture.duplicate_of_id.is_(None))
    ).scalars().all()
    latest = latest_inference_ids(session, [c.id for c in captures])
    category_of = {c.id: c.category_id for c in captures}
    if not latest:
        return [], []
    detections = session.execute(
        select(DetectedObject).where(DetectedObject.inference_id.in_(latest.values()))
    ).scalars().all()
    product_category = dict(session.execute(
        select(Product.id, Product.category_id).where(
            Product.id.in_({d.final_product_id for d in detections if d.final_product_id}))
    ).all())
    facings = [
        Facing(
            id=d.id, capture_id=d.capture_id,
            label="rejected" if d.verification == "rejected" else d.final_label,
            product_id=d.final_product_id, manufacturer_id=d.final_manufacturer_id,
            confidence=d.confidence, verified=d.verification in {"confirmed", "corrected"},
            y_center=d.y + d.height / 2, shelf_row=d.shelf_row, shelf_rows_total=d.shelf_rows_total,
            category_id=product_category.get(d.final_product_id) or category_of.get(d.capture_id),
        )
        for d in detections
    ]
    versions = sorted(set(session.execute(
        select(Inference.model_version_id).where(Inference.id.in_(latest.values()))
    ).scalars()))
    return facings, versions


def own_manufacturer_ids(session: Session, organization_id: str) -> set[str]:
    return set(session.execute(
        select(Manufacturer.id).where(Manufacturer.organization_id == organization_id, Manufacturer.is_own.is_(True))
    ).scalars())


def recompute_visit_measurements(session: Session, visit_id: str) -> None:
    visit = session.get(Visit, visit_id)
    if visit is None:
        return
    facings, versions = visit_facings(session, visit_id)
    session.execute(delete(ShelfMeasurement).where(ShelfMeasurement.visit_id == visit_id))
    own = own_manufacturer_ids(session, visit.organization_id)
    for basis in ("all", "verified"):
        summary = shelf.summarize(facings, own, basis)
        if not summary.total_facings:
            continue
        inputs = {"model_versions": versions, "unknown_facings": summary.unknown_facings,
                  "range": summary.share_of_shelf_range, "verified_ratio": summary.verified_ratio,
                  "generator_version": shelf.GENERATOR_VERSION}

        def add(metric: str, scope_type: str, scope_id: str | None, numerator: float, denominator: float) -> None:
            session.add(ShelfMeasurement(
                organization_id=visit.organization_id, data_origin=visit.data_origin, visit_id=visit.id,
                outlet_id=visit.outlet_id, metric=metric, scope_type=scope_type, scope_id=scope_id,
                numerator=numerator, denominator=denominator,
                value=round(numerator / denominator, 4) if denominator else 0.0, basis=basis, inputs=inputs,
            ))

        add("share_of_shelf", "own", None, summary.own_facings, summary.total_facings)
        for manufacturer_id, count in summary.facings_by_manufacturer.items():
            add("share_of_shelf", "manufacturer", manufacturer_id, count, summary.total_facings)
            add("facings", "manufacturer", manufacturer_id, count, 1)
        for product_id, count in summary.facings_by_product.items():
            add("facings", "product", product_id, count, 1)
            add("presence", "product", product_id, 1, 1)
        if summary.distinct_skus:
            add("share_of_assortment", "own", None, summary.distinct_own_skus, summary.distinct_skus)
    session.flush()


REVIEW_ACTIONS = {"confirm", "correct", "reject"}


def review_detection(
    session: Session,
    principal: Principal,
    detection: DetectedObject,
    action: str,
    label: str | None,
    product_id: str | None,
    reason: str | None,
) -> RecognitionCorrection:
    if action not in REVIEW_ACTIONS:
        raise ValueError(f"action must be one of {sorted(REVIEW_ACTIONS)}")
    inference = session.get(Inference, detection.inference_id)
    assert inference is not None
    new_label, new_product, new_manufacturer = detection.final_label, detection.final_product_id, detection.final_manufacturer_id
    if action == "correct":
        if product_id:
            product = session.get(Product, product_id)
            if product is None or product.organization_id != principal.organization_id:
                raise ValueError("Unknown product")
            manufacturer = session.get(Manufacturer, product.manufacturer_id)
            assert manufacturer is not None
            new_product, new_manufacturer = product.id, manufacturer.id
            new_label = "own" if manufacturer.is_own else "competitor"
        elif label in {"own", "competitor", "unknown"}:
            new_label, new_product = label, None
            new_manufacturer = next(iter(own_manufacturer_ids(session, principal.organization_id)), None) if label == "own" else None
        else:
            raise ValueError("correct requires product_id or label (own | competitor | unknown)")
    correction = RecognitionCorrection(
        organization_id=principal.organization_id, data_origin=detection.data_origin,
        detected_object_id=detection.id, user_id=principal.user_id,
        model_version_id=inference.model_version_id, action=action,
        previous_label=detection.final_label, previous_product_id=detection.final_product_id,
        new_label="rejected" if action == "reject" else new_label,
        new_product_id=None if action == "reject" else new_product,
        new_manufacturer_id=None if action == "reject" else new_manufacturer, reason=reason,
    )
    session.add(correction)
    if action == "reject":
        detection.verification = "rejected"
    else:
        changed = (new_label, new_product) != (detection.predicted_label, detection.predicted_product_id)
        detection.verification = "corrected" if changed else "confirmed"
        detection.final_label, detection.final_product_id, detection.final_manufacturer_id = new_label, new_product, new_manufacturer
    detection.needs_review = False
    session.flush()
    capture = session.get(ShelfCapture, detection.capture_id)
    assert capture is not None
    recompute_visit_measurements(session, capture.visit_id)
    audit.record(session, principal, f"detection.{action}", "detected_object", detection.id,
                 {"from": correction.previous_label, "to": correction.new_label,
                  "product": correction.new_product_id, "model_version_id": inference.model_version_id})
    CORRECTIONS.labels(action).inc()
    return correction
