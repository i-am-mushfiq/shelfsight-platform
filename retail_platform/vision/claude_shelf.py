"""Whole-shelf product recognition with a Claude multimodal model.

One request per photo. The model sees the full shelf photo, the closed catalogue (own and
competitor SKUs) and, when available, catalogue pack shots, and returns every run of
identical adjacent facings with a box, a catalogue product id or "unknown", and the brand
owner. Runs are split into one box per facing, so counts, shelf rows, placement and human
review work exactly as for any other provider.

Unlike the crop recogniser this does not depend on the OpenCV facing detector, whose recall
on real shelves is low. That detector is kept as the fallback when the API is unavailable,
refuses, or returns unusable output, so a field audit never stalls on a vendor outage; the
fallback is stated in the inference warnings and in each detection's evidence.

Closed set: product ids outside the catalogue are rejected (the JSON schema enumerates them
when the catalogue is small enough; otherwise they are validated here). Stated confidence
is recorded but treated as uncalibrated: the pipeline routes low-confidence and unknown
facings to human review, and calibration is measured against the corrections.
"""

from __future__ import annotations

import base64
import json
import logging
from dataclasses import dataclass, replace

import cv2
import numpy as np

from .base import CatalogEntry, ProviderDetection, ProviderResult, VisionProvider
from .llm_recognizer import _cost, _short_hash

log = logging.getLogger(__name__)

try:
    import anthropic

    _API_ERRORS: tuple[type[Exception], ...] = (anthropic.APIError,)
except ImportError:  # the llm extra is not installed; only injected test clients can be used
    anthropic = None  # type: ignore[assignment]
    _API_ERRORS = ()

SYSTEM_PROMPT = (
    "You audit retail shelves in shops in Bangladesh from photos. Packaging may carry Bangla "
    "and English text, and the same brand often comes in several pack sizes and variants.\n\n"
    "Report every product facing you can see: a facing is one front-facing unit of a product "
    "on the shelf. Group identical products standing side by side into one run, with a box "
    "tightly around the run and the number of facings in it. Ignore price tags, shelf strips, "
    "posters, hanging signs and reflections; include partly hidden packs when at least half of "
    "the front is visible.\n\n"
    "Identify each run with a product_id from the catalogue, or \"unknown\" when it is not "
    "clearly one of them (a product that is not listed, an unreadable pack, or a pack size or "
    "variant you cannot tell apart). A wrong product_id is worse than \"unknown\". When you can "
    "tell the brand owner but not the exact product, use product_id \"unknown\" and set "
    "manufacturer_id. Catalogue pack shots, when given, show what the listed products look "
    "like; artwork changes over time, so read the pack text as well.\n\n"
    "Boxes use integer coordinates from 0 to 1000 relative to the shelf photo: x from the left "
    "edge, y from the top edge. confidence is your probability that product_id is correct (or, "
    "for an unknown product, that manufacturer_id is). Set image_usable to false when the photo "
    "does not show a shelf or is too blurred or dark to read, and say why in notes."
)


@dataclass(frozen=True, slots=True)
class ShelfRecognizerConfig:
    model: str = "claude-opus-5-5"
    effort: str = "medium"
    max_image_side: int = 1600
    # Output is streamed, so a large ceiling costs nothing unless it is used.
    max_tokens: int = 32000
    max_facings_per_run: int = 40
    # Above this many catalogue products the id list is validated here instead of in the schema.
    enum_limit: int = 600
    min_box_side: float = 0.004


class ClaudeShelfRecognizer:
    provider = "claude-shelf"
    model_code = "shelf-recognition-llm"

    def __init__(self, fallback: VisionProvider | None = None, client=None,  # type: ignore[no-untyped-def]
                 config: ShelfRecognizerConfig | None = None) -> None:
        self.fallback = fallback
        self.recognizer_config = config or ShelfRecognizerConfig()
        if client is None:
            if anthropic is None:
                raise RuntimeError("claude-shelf needs the anthropic package: uv sync --extra llm")
            client = anthropic.Anthropic()
        self.client = client
        cfg = self.recognizer_config
        self.version = f"{cfg.model}/{cfg.effort}/{cfg.max_image_side}px/{_short_hash(SYSTEM_PROMPT)}"
        self.config = {
            "model": cfg.model, "effort": cfg.effort, "max_image_side": cfg.max_image_side,
            "max_facings_per_run": cfg.max_facings_per_run, "prompt_sha": _short_hash(SYSTEM_PROMPT),
            "fallback": {"provider": fallback.provider, "version": fallback.version} if fallback else None,
        }

    def analyze(self, image: bytes, catalog: list[CatalogEntry], own_manufacturer_id: str | None) -> ProviderResult:
        array = cv2.imdecode(np.frombuffer(image, dtype=np.uint8), cv2.IMREAD_COLOR)
        if array is None:
            raise ValueError("Unable to decode image")
        if not catalog:
            return self._fallback(image, catalog, own_manufacturer_id, "No catalogue to recognise against.")
        sent = _downscale_jpeg(array, self.recognizer_config.max_image_side)
        manufacturers = sorted({entry.manufacturer_id for entry in catalog})
        try:
            answer, cost, problem = self._request(sent, catalog, manufacturers)
        except _API_ERRORS as exc:
            log.warning("shelf recogniser request failed: %s", exc)
            return self._fallback(image, catalog, own_manufacturer_id, _describe_failure(exc))
        if answer is None:
            return self._fallback(image, catalog, own_manufacturer_id, problem or "Product recognition failed.",
                                  cost)
        by_id = {entry.product_id: entry for entry in catalog}
        detections, rejected = _detections(answer["runs"], by_id, set(manufacturers), own_manufacturer_id,
                                           self.recognizer_config)
        warnings: list[str] = []
        if not answer.get("image_usable", True):
            warnings.append(f"Photo may not be usable: {answer.get('notes') or 'no reason given'}.")
        if rejected:
            warnings.append(f"{rejected} answer(s) named products outside the catalogue and were set to unknown.")
        return ProviderResult(
            detections=detections, warnings=warnings, annotated_jpeg=_annotate(array, detections),
            cost_usd=round(cost, 6),
            raw={"runs": len(answer["runs"]), "facings": len(detections), "notes": answer.get("notes", "")[:500],
                 "image_usable": answer.get("image_usable", True)},
        )

    def _request(self, shelf_jpeg: bytes, catalog: list[CatalogEntry], manufacturers: list[str]):  # type: ignore[no-untyped-def]
        cfg = self.recognizer_config
        catalogue_text = "\n".join(
            f"{e.product_id} | {'own' if e.is_own else 'competitor'} | {e.manufacturer} ({e.manufacturer_id}) | "
            f"{e.brand} | {e.name} | {e.category} | {e.pack or ''}"
            for e in catalog
        )
        # Stable prefix first (catalogue and pack shots are identical for every photo of the
        # same catalogue scope), cached; the shelf photo comes after the breakpoint.
        stable: list[dict] = [{
            "type": "text",
            "text": "Catalogue (product_id | own/competitor | manufacturer (manufacturer_id) | brand | name | "
                    "category | pack):\n" + catalogue_text,
        }]
        for entry in catalog:
            for shot in entry.reference_images:
                stable.append({"type": "text", "text": f"Pack shot of {entry.product_id} ({entry.name}):"})
                stable.append(_image_block(shot))
        stable[-1] = {**stable[-1], "cache_control": {"type": "ephemeral"}}
        content = stable + [
            {"type": "text", "text": "Shelf photo:"},
            _image_block(shelf_jpeg),
            {"type": "text", "text": "List every facing run on this shelf."},
        ]
        product_ids = [e.product_id for e in catalog]
        product_schema: dict = {"type": "string"}
        if len(product_ids) <= cfg.enum_limit:
            product_schema["enum"] = product_ids + ["unknown"]
        run_schema = {
            "type": "object",
            "properties": {
                "x_min": {"type": "integer"}, "y_min": {"type": "integer"},
                "x_max": {"type": "integer"}, "y_max": {"type": "integer"},
                "facings": {"type": "integer"},
                "product_id": product_schema,
                "manufacturer_id": {"type": "string", "enum": manufacturers + ["unknown"]},
                "confidence": {"type": "number"},
                "visible_text": {"type": "string"},
            },
            "required": ["x_min", "y_min", "x_max", "y_max", "facings", "product_id", "manufacturer_id",
                         "confidence", "visible_text"],
            "additionalProperties": False,
        }
        schema = {
            "type": "object",
            "properties": {
                "image_usable": {"type": "boolean"},
                "notes": {"type": "string"},
                "runs": {"type": "array", "items": run_schema},
            },
            "required": ["image_usable", "notes", "runs"],
            "additionalProperties": False,
        }
        with self.client.beta.messages.stream(
            model=cfg.model,
            max_tokens=cfg.max_tokens,
            system=SYSTEM_PROMPT,
            messages=[{"role": "user", "content": content}],
            output_config={"effort": cfg.effort, "format": {"type": "json_schema", "schema": schema}},
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
        ) as stream:
            response = stream.get_final_message()
        cost = _cost(cfg.model, response.usage)
        if response.stop_reason == "refusal":
            return None, cost, "Product recognition declined by the model."
        if response.stop_reason == "max_tokens":
            return None, cost, "Product recognition output was truncated (too many products in one photo)."
        text = next((block.text for block in response.content if block.type == "text"), "")
        try:
            answer = json.loads(text)
            if not isinstance(answer.get("runs"), list):
                raise TypeError
        except (json.JSONDecodeError, TypeError, AttributeError):
            return None, cost, "Product recognition returned unreadable output."
        return answer, cost, None

    def _fallback(self, image: bytes, catalog: list[CatalogEntry], own_manufacturer_id: str | None,
                  reason: str, cost: float = 0.0) -> ProviderResult:
        if self.fallback is None:
            raise RuntimeError(reason)
        result = self.fallback.analyze(image, catalog, own_manufacturer_id)
        result.detections = [replace(d, evidence={**d.evidence, "fallback_from": self.provider})
                             for d in result.detections]
        result.warnings = [f"{reason} Showing the basic {self.fallback.provider} detection instead."] + result.warnings
        result.cost_usd = round(cost, 6) or result.cost_usd
        result.raw = {**result.raw, "fallback": reason}
        return result


def _describe_failure(exc: Exception) -> str:
    if isinstance(exc, anthropic.RateLimitError):
        return "Product recognition is rate limited right now."
    if isinstance(exc, anthropic.APIStatusError):
        return f"Product recognition service error (HTTP {exc.status_code})."
    if isinstance(exc, anthropic.APIConnectionError):
        return "Product recognition service unreachable."
    return f"Product recognition unavailable ({type(exc).__name__})."


def _detections(runs: list[dict], by_id: dict[str, CatalogEntry], manufacturers: set[str],
                own_manufacturer_id: str | None, cfg: ShelfRecognizerConfig) -> tuple[list[ProviderDetection], int]:
    detections: list[ProviderDetection] = []
    rejected = 0
    for index, run in enumerate(runs):
        try:
            x0, y0, x1, y1 = (min(1.0, max(0.0, float(run[k]) / 1000)) for k in ("x_min", "y_min", "x_max", "y_max"))
            count = int(run.get("facings") or 1)
            confidence = min(1.0, max(0.0, float(run.get("confidence", 0.0))))
        except (KeyError, TypeError, ValueError):
            continue
        x0, x1 = min(x0, x1), max(x0, x1)
        y0, y1 = min(y0, y1), max(y0, y1)
        if x1 - x0 < cfg.min_box_side or y1 - y0 < cfg.min_box_side:
            continue
        count = max(1, min(count, cfg.max_facings_per_run))
        answered = str(run.get("product_id", "unknown"))
        manufacturer = str(run.get("manufacturer_id", "unknown"))
        if manufacturer not in manufacturers:
            manufacturer = "unknown"
        entry = by_id.get(answered)
        if entry is None and answered != "unknown":
            rejected += 1
        if entry is not None:
            label, product_id, manufacturer_id = ("own" if entry.is_own else "competitor"), entry.product_id, entry.manufacturer_id
        elif manufacturer != "unknown":
            label = "own" if manufacturer == own_manufacturer_id else "competitor"
            product_id, manufacturer_id = None, manufacturer
            confidence = round(confidence * 0.9, 4)  # brand owner only: weaker than a SKU match
        else:
            label, product_id, manufacturer_id = "unknown", None, None
        evidence = {"recognizer": {
            "product_id": answered, "manufacturer_id": run.get("manufacturer_id"), "stated_confidence": confidence,
            "visible_text": str(run.get("visible_text", ""))[:200], "run_index": index, "run_facings": count,
        }}
        width = (x1 - x0) / count
        for k in range(count):
            detections.append(ProviderDetection(
                x=round(x0 + k * width, 5), y=round(y0, 5), width=round(width, 5), height=round(y1 - y0, 5),
                label=label, confidence=confidence, product_id=product_id, manufacturer_id=manufacturer_id,
                evidence=evidence,
            ))
    return detections, rejected


def _downscale_jpeg(image: np.ndarray, max_side: int, quality: int = 88) -> bytes:
    scale = max_side / max(image.shape[:2])
    if scale < 1:
        image = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    ok, encoded = cv2.imencode(".jpg", image, [int(cv2.IMWRITE_JPEG_QUALITY), quality])
    if not ok:
        raise ValueError("Unable to encode image")
    return encoded.tobytes()


def _image_block(jpeg: bytes) -> dict:
    return {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg",
                                        "data": base64.standard_b64encode(jpeg).decode()}}


_COLOURS = {"own": (94, 197, 34), "competitor": (60, 60, 220), "unknown": (11, 158, 245)}  # BGR


def _annotate(image: np.ndarray, detections: list[ProviderDetection]) -> bytes | None:
    canvas = image.copy()
    height, width = canvas.shape[:2]
    thickness = max(2, round(max(height, width) / 500))
    for d in detections:
        top_left = (int(d.x * width), int(d.y * height))
        bottom_right = (int((d.x + d.width) * width), int((d.y + d.height) * height))
        cv2.rectangle(canvas, top_left, bottom_right, _COLOURS.get(d.label, _COLOURS["unknown"]), thickness)
    ok, encoded = cv2.imencode(".jpg", canvas, [int(cv2.IMWRITE_JPEG_QUALITY), 85])
    return encoded.tobytes() if ok else None
