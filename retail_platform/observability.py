"""Structured logging, request ids and Prometheus metrics."""

from __future__ import annotations

import contextvars
import json
import logging
import time
import uuid

from prometheus_client import Counter, Histogram
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response

request_id_var: contextvars.ContextVar[str | None] = contextvars.ContextVar("request_id", default=None)

HTTP_REQUESTS = Counter(
    "shelfsight_http_requests_total", "HTTP requests", ["method", "route", "status"]
)
HTTP_LATENCY = Histogram(
    "shelfsight_http_request_seconds", "HTTP request latency", ["method", "route"]
)
INFERENCES = Counter(
    "shelfsight_inferences_total", "Vision inferences", ["provider", "status"]
)
INFERENCE_LATENCY = Histogram(
    "shelfsight_inference_seconds", "Vision inference latency", ["provider"],
    buckets=(0.25, 0.5, 1, 2, 5, 10, 20, 40, 80),
)
INFERENCE_COST = Counter("shelfsight_inference_cost_usd_total", "Inference cost", ["provider"])
CORRECTIONS = Counter("shelfsight_detection_reviews_total", "Detection reviews", ["action"])
RECOMMENDATION_FEEDBACK = Counter(
    "shelfsight_recommendation_feedback_total", "Recommendation feedback", ["type", "decision"]
)
UPLOADS = Counter("shelfsight_capture_uploads_total", "Capture uploads", ["outcome"])
JOBS = Counter("shelfsight_jobs_total", "Background jobs", ["kind", "status"])


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S"),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
            "request_id": request_id_var.get(),
        }
        extra = getattr(record, "fields", None)
        if extra:
            payload.update(extra)
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def configure_logging(level: str = "INFO") -> None:
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level)


class RequestContextMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next) -> Response:  # type: ignore[no-untyped-def]
        request_id = request.headers.get("x-request-id") or uuid.uuid4().hex
        token = request_id_var.set(request_id)
        started = time.perf_counter()
        status = 500
        try:
            response = await call_next(request)
            status = response.status_code
            response.headers["x-request-id"] = request_id
            return response
        finally:
            route = request.scope.get("route")
            route_path = getattr(route, "path", "unmatched")
            elapsed = time.perf_counter() - started
            HTTP_REQUESTS.labels(request.method, route_path, str(status)).inc()
            HTTP_LATENCY.labels(request.method, route_path).observe(elapsed)
            logging.getLogger("http").info(
                "request",
                extra={"fields": {
                    "method": request.method, "route": route_path, "status": status,
                    "ms": round(elapsed * 1000, 1),
                }},
            )
            request_id_var.reset(token)
