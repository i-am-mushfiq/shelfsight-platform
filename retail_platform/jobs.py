"""Durable DB-backed job queue. Good enough for one or a few workers; replaceable by a broker
later without schema change (jobs stay idempotent rows)."""

from __future__ import annotations

import logging
import threading
import traceback
from collections.abc import Callable
from datetime import timedelta

from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, sessionmaker

from .models import Job, utcnow
from .observability import JOBS

log = logging.getLogger(__name__)

Handler = Callable[[Session, Job], None]
_handlers: dict[str, Handler] = {}


def handler(kind: str) -> Callable[[Handler], Handler]:
    def register(fn: Handler) -> Handler:
        _handlers[kind] = fn
        return fn
    return register


def enqueue(session: Session, organization_id: str, kind: str, dedupe_key: str, payload: dict,
            data_origin: str = "production") -> Job:
    existing = session.execute(
        select(Job).where(Job.organization_id == organization_id, Job.kind == kind, Job.dedupe_key == dedupe_key)
    ).scalar_one_or_none()
    if existing is not None:
        return existing
    job = Job(organization_id=organization_id, kind=kind, dedupe_key=dedupe_key, payload=payload,
              data_origin=data_origin)
    session.add(job)
    try:
        session.flush()
    except IntegrityError:
        session.rollback()
        return session.execute(
            select(Job).where(Job.organization_id == organization_id, Job.kind == kind, Job.dedupe_key == dedupe_key)
        ).scalar_one()
    return job


def _claim(session: Session) -> Job | None:
    now = utcnow()
    stale = now - timedelta(minutes=15)
    candidate = session.execute(
        select(Job.id).where(
            ((Job.status == "pending") & (Job.run_after <= now))
            | ((Job.status == "running") & (Job.locked_at < stale))
        ).order_by(Job.run_after).limit(1)
    ).scalar_one_or_none()
    if candidate is None:
        return None
    # Optimistic claim: only one worker's UPDATE matches the previous state.
    claimed = session.execute(
        update(Job).where(Job.id == candidate, Job.status.in_(("pending", "running")),
                          (Job.locked_at.is_(None)) | (Job.locked_at < stale))
        .values(status="running", locked_at=now, attempts=Job.attempts + 1)
    ).rowcount
    session.commit()
    if not claimed:
        return None
    return session.get(Job, candidate)


def run_one(factory: sessionmaker[Session]) -> bool:
    with factory() as session:
        job = _claim(session)
        if job is None:
            return False
        fn = _handlers.get(job.kind)
        try:
            if fn is None:
                raise RuntimeError(f"No handler for job kind {job.kind}")
            fn(session, job)
            job.status = "done"
            job.last_error = None
            session.commit()
            JOBS.labels(job.kind, "done").inc()
        except Exception as exc:  # noqa: BLE001 - job failures must not kill the worker
            session.rollback()
            job = session.get(Job, job.id)
            assert job is not None
            job.last_error = (str(exc) + "\n" + traceback.format_exc())[-2000:]
            if job.attempts >= job.max_attempts:
                job.status = "failed"
                JOBS.labels(job.kind, "failed").inc()
            else:
                job.status = "pending"
                job.run_after = utcnow() + timedelta(seconds=30 * 2 ** job.attempts)
                JOBS.labels(job.kind, "retry").inc()
            job.locked_at = None
            session.commit()
            log.exception("job failed", extra={"fields": {"job_id": job.id, "kind": job.kind}})
        return True


def drain(factory: sessionmaker[Session], limit: int = 100) -> int:
    """Run ready jobs synchronously (tests, CLI)."""
    count = 0
    while count < limit and run_one(factory):
        count += 1
    return count


class Worker(threading.Thread):
    def __init__(self, factory: sessionmaker[Session], interval: float = 1.0) -> None:
        super().__init__(name="shelfsight-worker", daemon=True)
        self.factory = factory
        self.interval = interval
        self._stop_event = threading.Event()

    def run(self) -> None:
        while not self._stop_event.is_set():
            try:
                worked = run_one(self.factory)
            except Exception:  # noqa: BLE001
                log.exception("worker loop error")
                worked = False
            if not worked:
                self._stop_event.wait(self.interval)

    def stop(self) -> None:
        self._stop_event.set()
