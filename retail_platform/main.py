from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import PlainTextResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from sqlalchemy import text

from . import db
from .api import admin, analytics, auth, catalog, outlets, visits
from .config import get_settings
from .jobs import Worker
from .observability import RequestContextMiddleware, configure_logging
from .vision import pipeline  # noqa: F401  (registers job handlers)

log = logging.getLogger(__name__)


def migrate() -> None:
    from alembic import command
    from alembic.config import Config

    config = Config(os.path.join(os.path.dirname(__file__), "migrations", "alembic.ini"))
    config.set_main_option("script_location", os.path.join(os.path.dirname(__file__), "migrations"))
    config.set_main_option("sqlalchemy.url", get_settings().database_url)
    command.upgrade(config, "head")


def create_app(run_worker: bool | None = None, auto_migrate: bool | None = None, mount_legacy: bool = True) -> FastAPI:
    settings = get_settings()
    if os.getenv("SHELFSIGHT_JSON_LOGS", "1") == "1":
        configure_logging(os.getenv("SHELFSIGHT_LOG_LEVEL", "INFO"))
    run_worker = settings.run_worker if run_worker is None else run_worker
    auto_migrate = (os.getenv("SHELFSIGHT_MIGRATE_ON_START", "1") == "1") if auto_migrate is None else auto_migrate

    @asynccontextmanager
    async def lifespan(_: FastAPI):  # type: ignore[no-untyped-def]
        if auto_migrate:
            migrate()
        worker = Worker(db.session_factory()) if run_worker else None
        if worker:
            worker.start()
        yield
        if worker:
            worker.stop()

    app = FastAPI(
        title="ShelfSight Retail Intelligence Platform",
        version="0.2.0",
        description="Outlet, portfolio, competitor, placement and shelf intelligence for field sales.",
        lifespan=lifespan,
    )
    app.add_middleware(RequestContextMiddleware)
    origins = [o for o in os.getenv("SHELFSIGHT_CORS_ORIGINS", "").split(",") if o]
    if origins:
        app.add_middleware(CORSMiddleware, allow_origins=origins, allow_methods=["*"], allow_headers=["*"])
    for module in (auth, catalog, outlets, visits, analytics, admin):
        app.include_router(module.router)

    @app.get("/health", tags=["ops"])
    def health() -> dict:
        with db.engine().connect() as connection:
            connection.execute(text("SELECT 1"))
        return {"status": "ok", "service": "shelfsight-platform", "version": app.version,
                "vision_provider": settings.vision_provider, "environment": settings.environment}

    @app.get("/metrics", include_in_schema=False)
    def metrics() -> PlainTextResponse:
        return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)

    if mount_legacy:
        # Keep the already-distributed v1 app working (/v1/analyze, /artifacts/*) during migration.
        from ai_service.app import app as legacy

        app.mount("/", legacy)
    return app


app = create_app()
