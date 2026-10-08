from __future__ import annotations

import json
from types import SimpleNamespace

from sqlalchemy import select

from retail_platform import db, jobs
from retail_platform.models import Job
from retail_platform.vision.base import CatalogEntry, ProviderDetection, ProviderResult
from retail_platform.vision.fake import ScriptedProvider
from retail_platform.vision.llm_recognizer import ClaudeCropRecognizer

from .conftest import shelf_jpeg

CATALOG = [
    CatalogEntry("p-meril", "SQ-1", "Meril Soap 100g", "Meril", "m-sq", "Square", True, "Bar Soap", "100g"),
    CatalogEntry("p-lux", "UNI-1", "Lux Soap 100g", "Lux", "m-uni", "Unilever", False, "Bar Soap", "100g"),
]


class FakeMessages:
    def __init__(self, payload: dict | None, stop_reason: str = "end_turn") -> None:
        self.payload = payload
        self.stop_reason = stop_reason
        self.calls: list[dict] = []

    def create(self, **kwargs):  # type: ignore[no-untyped-def]
        self.calls.append(kwargs)
        text = json.dumps(self.payload) if self.payload is not None else ""
        return SimpleNamespace(
            stop_reason=self.stop_reason,
            content=[SimpleNamespace(type="text", text=text)],
            usage=SimpleNamespace(input_tokens=1000, output_tokens=200, cache_creation_input_tokens=0, cache_read_input_tokens=0),
        )


def _recognizer(payload, stop_reason="end_turn"):  # type: ignore[no-untyped-def]
    detector = ScriptedProvider([
        ProviderDetection(0.1, 0.1, 0.2, 0.3, "unknown", 0.4),
        ProviderDetection(0.4, 0.1, 0.2, 0.3, "unknown", 0.4),
        ProviderDetection(0.7, 0.1, 0.2, 0.3, "unknown", 0.4),
    ])
    messages = FakeMessages(payload, stop_reason)
    client = SimpleNamespace(beta=SimpleNamespace(messages=messages))
    return ClaudeCropRecognizer(detector, client=client), messages


def test_recognizer_maps_closed_set_answers():
    recognizer, messages = _recognizer({"crops": [
        {"crop_index": 0, "product_id": "p-meril", "manufacturer_id": "m-sq", "confidence": 0.93, "visible_text": "Meril"},
        {"crop_index": 1, "product_id": "unknown", "manufacturer_id": "m-uni", "confidence": 0.7, "visible_text": ""},
        {"crop_index": 2, "product_id": "unknown", "manufacturer_id": "unknown", "confidence": 0.1, "visible_text": ""},
    ]})
    result = recognizer.analyze(shelf_jpeg(), CATALOG, "m-sq")
    first, second, third = result.detections
    assert (first.label, first.product_id, first.confidence) == ("own", "p-meril", 0.93)
    assert (second.label, second.product_id, second.manufacturer_id) == ("competitor", None, "m-uni")
    assert third.label == "unknown" and third.product_id is None
    schema = messages.calls[0]["output_config"]["format"]["schema"]
    enum = schema["properties"]["crops"]["items"]["properties"]["product_id"]["enum"]
    assert enum == ["p-meril", "p-lux", "unknown"]  # model cannot answer outside the catalogue
    assert result.cost_usd == round((1000 * 4 + 200 * 20) / 1_000_000, 6)
    assert "claude-opus-5-5" in recognizer.version


def test_recognizer_refusal_keeps_detector_output():
    recognizer, _ = _recognizer(None, stop_reason="refusal")
    result = recognizer.analyze(shelf_jpeg(), CATALOG, "m-sq")
    assert all(d.label == "unknown" for d in result.detections)
    assert any("declined" in w for w in result.warnings)


def test_recognizer_ignores_out_of_range_crop_indexes():
    recognizer, _ = _recognizer({"crops": [
        {"crop_index": 9, "product_id": "p-lux", "manufacturer_id": "m-uni", "confidence": 0.9, "visible_text": ""}]})
    result = recognizer.analyze(shelf_jpeg(), CATALOG, "m-sq")
    assert all(d.product_id is None for d in result.detections)


def test_job_retries_then_fails(platform):
    calls = {"n": 0}

    @jobs.handler("always_fails")
    def _fail(session, job):  # type: ignore[no-untyped-def]
        calls["n"] += 1
        raise RuntimeError("boom")

    factory = db.session_factory()
    with factory() as session:
        job = jobs.enqueue(session, platform["org_id"], "always_fails", "k1", {}, data_origin="synthetic")
        job.max_attempts = 2
        session.commit()
        job_id = job.id
        assert jobs.enqueue(session, platform["org_id"], "always_fails", "k1", {}).id == job_id  # idempotent
    jobs.run_one(factory)
    with factory() as session:
        job = session.get(Job, job_id)
        assert job.status == "pending" and job.attempts == 1 and "boom" in job.last_error
        job.run_after = job.created_at  # make it due now
        session.commit()
    jobs.run_one(factory)
    with factory() as session:
        assert session.execute(select(Job.status).where(Job.id == job_id)).scalar_one() == "failed"
    assert calls["n"] == 2


def test_scripted_result_type():
    assert isinstance(ScriptedProvider().analyze(b"", [], None), ProviderResult)
