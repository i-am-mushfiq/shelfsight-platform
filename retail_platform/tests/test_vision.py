from __future__ import annotations

import contextlib
import json
from dataclasses import replace
from types import SimpleNamespace

import anthropic
import httpx2
import pytest

from sqlalchemy import select

from retail_platform import db, jobs
from retail_platform.models import Job
from retail_platform.vision.base import CatalogEntry, ProviderDetection, ProviderResult
from retail_platform.vision.fake import ScriptedProvider
from retail_platform.vision.llm_recognizer import ClaudeCropRecognizer
from retail_platform.vision.claude_shelf import ClaudeShelfRecognizer, ShelfRecognizerConfig

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



# --- whole-shelf recogniser ---------------------------------------------------------------------

class FakeShelfMessages:
    """Stands in for client.beta.messages: records the request, streams back a canned message."""

    def __init__(self, payload=None, stop_reason="end_turn", error=None):  # type: ignore[no-untyped-def]
        self.payload, self.stop_reason, self.error = payload, stop_reason, error
        self.calls: list[dict] = []

    def stream(self, **kwargs):  # type: ignore[no-untyped-def]
        self.calls.append(kwargs)
        if self.error is not None:
            raise self.error
        message = SimpleNamespace(
            stop_reason=self.stop_reason,
            content=[SimpleNamespace(type="text", text=json.dumps(self.payload) if self.payload is not None else "")],
            usage=SimpleNamespace(input_tokens=3000, output_tokens=800, cache_creation_input_tokens=0,
                                  cache_read_input_tokens=0),
        )
        return contextlib.nullcontext(SimpleNamespace(get_final_message=lambda: message))


def _run(x0, x1, facings, product, manufacturer, confidence=0.9, y0=100, y1=300):  # type: ignore[no-untyped-def]
    return {"x_min": x0, "y_min": y0, "x_max": x1, "y_max": y1, "facings": facings, "product_id": product,
            "manufacturer_id": manufacturer, "confidence": confidence, "visible_text": ""}


def _shelf_recognizer(payload=None, stop_reason="end_turn", error=None, config=None):  # type: ignore[no-untyped-def]
    messages = FakeShelfMessages(payload, stop_reason, error)
    fallback = ScriptedProvider([ProviderDetection(0.1, 0.1, 0.2, 0.3, "unknown", 0.4)])
    recognizer = ClaudeShelfRecognizer(fallback, client=SimpleNamespace(beta=SimpleNamespace(messages=messages)),
                                       config=config)
    return recognizer, messages, fallback


def test_shelf_recognizer_splits_runs_and_keeps_answers_in_the_catalogue():
    recognizer, messages, fallback = _shelf_recognizer({"image_usable": True, "notes": "", "runs": [
        _run(0, 300, 3, "p-meril", "m-uni", 0.92),          # SKU match: manufacturer comes from the catalogue
        _run(300, 500, 2, "unknown", "m-uni", 0.8),         # brand owner only
        _run(500, 600, 1, "unknown", "unknown", 0.3),       # nothing known
        _run(700, 700, 1, "p-lux", "m-uni"),                # zero-width box: dropped
        _run(900, 1200, 1, "p-lux", "m-uni", 1.7),          # clamped to the image and to confidence 1
    ]})
    catalog = [replace(CATALOG[0], reference_images=(shelf_jpeg(3),)), CATALOG[1]]
    result = recognizer.analyze(shelf_jpeg(), catalog, "m-sq")
    labels = [(d.label, d.product_id, d.manufacturer_id) for d in result.detections]
    assert labels[:3] == [("own", "p-meril", "m-sq")] * 3
    assert labels[3:5] == [("competitor", None, "m-uni")] * 2
    assert labels[5] == ("unknown", None, None)
    assert labels[6] == ("competitor", "p-lux", "m-uni") and len(labels) == 7
    first, second = result.detections[:2]
    assert first.x == 0 and first.width == pytest.approx(0.1) and second.x == pytest.approx(0.1)
    assert result.detections[3].confidence == pytest.approx(0.72)  # 0.8 × 0.9 for a brand-only answer
    assert result.detections[6].x == 0.9 and result.detections[6].width == pytest.approx(0.1)
    assert result.detections[6].confidence == 1.0
    assert result.annotated_jpeg and result.cost_usd == round((3000 * 4 + 800 * 20) / 1_000_000, 6)
    assert fallback.calls == 0

    request = messages.calls[0]
    assert request["model"] == "claude-opus-5-5" and request["fallbacks"] == "default"
    assert request["betas"] == ["server-side-fallback-2026-07-01"]
    assert request["output_config"]["effort"] == "medium"
    run_schema = request["output_config"]["format"]["schema"]["properties"]["runs"]["items"]
    assert run_schema["properties"]["product_id"]["enum"] == ["p-meril", "p-lux", "unknown"]
    content = request["messages"][0]["content"]
    images = [block for block in content if block["type"] == "image"]
    assert len(images) == 2  # one pack shot + the shelf photo
    cached = [i for i, block in enumerate(content) if "cache_control" in block]
    assert cached == [content.index(images[0])]  # the stable prefix ends with the last pack shot


def test_shelf_recognizer_rejects_ids_outside_the_catalogue_when_not_enumerated():
    recognizer, messages, _ = _shelf_recognizer(
        {"image_usable": True, "notes": "", "runs": [_run(0, 200, 1, "p-invented", "m-uni", 0.9)]},
        config=ShelfRecognizerConfig(enum_limit=1))
    result = recognizer.analyze(shelf_jpeg(), CATALOG, "m-sq")
    (detection,) = result.detections
    assert (detection.label, detection.product_id, detection.manufacturer_id) == ("competitor", None, "m-uni")
    assert any("outside the catalogue" in w for w in result.warnings)
    product_schema = messages.calls[0]["output_config"]["format"]["schema"]["properties"]["runs"]["items"]["properties"]["product_id"]
    assert "enum" not in product_schema


@pytest.mark.parametrize("kwargs, warning", [
    ({"error": anthropic.APIConnectionError(request=httpx2.Request("POST", "https://api.anthropic.com/v1/messages"))},
     "unreachable"),
    ({"payload": None, "stop_reason": "refusal"}, "declined"),
    ({"payload": {"image_usable": True, "notes": "", "runs": []}, "stop_reason": "max_tokens"}, "truncated"),
    ({"payload": {"unexpected": True}}, "unreadable"),
])
def test_shelf_recognizer_falls_back_to_the_detector(kwargs, warning):
    recognizer, _, fallback = _shelf_recognizer(**kwargs)
    result = recognizer.analyze(shelf_jpeg(), CATALOG, "m-sq")
    assert fallback.calls == 1
    assert warning in result.warnings[0] and "basic scripted detection" in result.warnings[0]
    assert result.detections[0].evidence["fallback_from"] == "claude-shelf"


def test_shelf_recognizer_reports_unusable_photos():
    recognizer, _, _ = _shelf_recognizer({"image_usable": False, "notes": "Photo shows the ceiling", "runs": []})
    result = recognizer.analyze(shelf_jpeg(), CATALOG, "m-sq")
    assert result.detections == [] and "ceiling" in result.warnings[0]


def test_auto_provider_uses_claude_only_with_credentials(monkeypatch):
    from retail_platform.config import Settings
    from retail_platform.vision.registry import resolve_provider_name

    settings = Settings(jwt_secret="x" * 40, vision_provider="auto")
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("ANTHROPIC_AUTH_TOKEN", raising=False)
    monkeypatch.setenv("SHELFSIGHT_VISUAL_LOOKUP", "0")
    assert resolve_provider_name(settings) == "packshot-match"
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")
    assert resolve_provider_name(settings) == "packshot-match"  # never an LLM unless named
    monkeypatch.setattr("retail_platform.vision.visual_lookup.available", lambda: True)
    assert resolve_provider_name(settings) == "visual-lookup"  # preferred when PyTorch is installed
    assert resolve_provider_name(replace(settings, vision_provider="claude-shelf")) == "claude-shelf"
    assert resolve_provider_name(replace(settings, vision_provider="opencv-baseline")) == "opencv-baseline"
    with pytest.raises(ValueError):
        resolve_provider_name(replace(settings, vision_provider="yolo-v99"))
