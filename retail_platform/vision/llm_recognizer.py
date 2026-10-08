"""Closed-set SKU recognition of detected facings with a Claude multimodal model.

Pipeline: an existing detector proposes facing boxes → each box is cropped → crops are
sent in small batches with the catalogue → the model must answer, per crop, with a
catalogue product id or "unknown" (enforced by a JSON-schema enum, so it cannot invent
SKUs). Its stated confidence is recorded as evidence but treated as uncalibrated: the
pipeline still routes low-confidence answers to human review, and calibration is
measured against human corrections.
"""

from __future__ import annotations

import base64
import json
import logging
from dataclasses import dataclass, replace

import cv2
import numpy as np

from .base import CatalogEntry, ProviderDetection, ProviderResult, VisionProvider

log = logging.getLogger(__name__)

# USD per million tokens (input, output). Configurable; keep in sync with the vendor price list.
PRICES = {"claude-opus-5-5": (4.0, 20.0), "claude-sonnet-5-5": (2.0, 10.0), "claude-haiku-4-5": (1.0, 5.0)}

SYSTEM_PROMPT = (
    "You identify retail products in cropped photos of shelf facings from shops in Bangladesh. "
    "Packaging may show Bangla and English text. For each crop, choose the single best matching "
    "product id from the catalogue provided, or \"unknown\" if the crop is not clearly one of them "
    "(wrong brand, unreadable, not a product, or a pack size you cannot tell apart). Prefer "
    "\"unknown\" over a guess: a wrong id is worse than an abstention. If you can tell the brand "
    "owner but not the exact SKU, return product_id \"unknown\" and set manufacturer_id. "
    "confidence is your probability (0-1) that product_id is correct."
)


@dataclass(frozen=True, slots=True)
class RecognizerConfig:
    model: str = "claude-opus-5-5"
    effort: str = "low"
    crops_per_request: int = 16
    crop_max_side: int = 384
    max_tokens: int = 4096


class ClaudeCropRecognizer:
    """Wraps a detector provider and adds SKU identity to its boxes."""

    provider = "claude-crop-recognizer"

    def __init__(self, detector: VisionProvider, client=None, config: RecognizerConfig | None = None) -> None:  # type: ignore[no-untyped-def]
        self.detector = detector
        self.recognizer_config = config or RecognizerConfig()
        if client is None:
            import anthropic

            client = anthropic.Anthropic()
        self.client = client
        self.model_code = "shelf-sku-recognition-llm"
        self.version = f"{self.recognizer_config.model}/{self.recognizer_config.effort}+{detector.version}"
        self.config = {
            "recognizer": {
                "model": self.recognizer_config.model, "effort": self.recognizer_config.effort,
                "crops_per_request": self.recognizer_config.crops_per_request,
                "crop_max_side": self.recognizer_config.crop_max_side,
            },
            "detector": {"provider": detector.provider, "version": detector.version, **detector.config},
            "prompt_sha": _short_hash(SYSTEM_PROMPT),
        }

    def analyze(self, image: bytes, catalog: list[CatalogEntry], own_manufacturer_id: str | None) -> ProviderResult:
        base = self.detector.analyze(image, catalog, own_manufacturer_id)
        if not base.detections or not catalog:
            return base
        array = cv2.imdecode(np.frombuffer(image, dtype=np.uint8), cv2.IMREAD_COLOR)
        if array is None:
            raise ValueError("Unable to decode image")
        by_id = {entry.product_id: entry for entry in catalog}
        manufacturers = sorted({entry.manufacturer_id for entry in catalog})
        detections = list(base.detections)
        cost = 0.0
        warnings = list(base.warnings)
        size = self.recognizer_config.crops_per_request
        for start in range(0, len(detections), size):
            chunk = list(range(start, min(start + size, len(detections))))
            crops = [_crop_jpeg(array, detections[i], self.recognizer_config.crop_max_side) for i in chunk]
            answers, chunk_cost, warning = self._recognize(crops, catalog, manufacturers)
            cost += chunk_cost
            if warning:
                warnings.append(warning)
            for offset, index in enumerate(chunk):
                answer = answers.get(offset)
                if answer is None:
                    continue
                detections[index] = _merge(detections[index], answer, by_id, own_manufacturer_id)
        warnings = [w for w in warnings if "SKUs and competitor brands are not recognised" not in w]
        return ProviderResult(detections=detections, warnings=warnings, annotated_jpeg=base.annotated_jpeg,
                              cost_usd=round(cost, 6), raw={"detector": base.raw})

    def _recognize(self, crops: list[bytes], catalog: list[CatalogEntry], manufacturers: list[str]):  # type: ignore[no-untyped-def]
        import anthropic

        catalogue_text = "\n".join(
            f"{e.product_id} | {e.manufacturer} ({e.manufacturer_id}) | {e.brand} | {e.name} | {e.category} | {e.pack or ''}"
            for e in catalog
        )
        # The catalogue is identical across requests: cache it (it follows the frozen system prompt).
        content: list[dict] = [{
            "type": "text",
            "text": "Catalogue (product_id | manufacturer (manufacturer_id) | brand | name | category | pack):\n" + catalogue_text,
            "cache_control": {"type": "ephemeral"},
        }]
        for index, crop in enumerate(crops):
            content.append({"type": "text", "text": f"Crop {index}:"})
            content.append({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg",
                                                        "data": base64.standard_b64encode(crop).decode()}})
        content.append({"type": "text", "text": f"Identify all {len(crops)} crops."})
        schema = {
            "type": "object",
            "properties": {"crops": {"type": "array", "items": {
                "type": "object",
                "properties": {
                    "crop_index": {"type": "integer"},
                    "product_id": {"type": "string", "enum": [e.product_id for e in catalog] + ["unknown"]},
                    "manufacturer_id": {"type": "string", "enum": manufacturers + ["unknown"]},
                    "confidence": {"type": "number"},
                    "visible_text": {"type": "string"},
                },
                "required": ["crop_index", "product_id", "manufacturer_id", "confidence", "visible_text"],
                "additionalProperties": False,
            }}},
            "required": ["crops"],
            "additionalProperties": False,
        }
        try:
            response = self.client.beta.messages.create(
                model=self.recognizer_config.model,
                max_tokens=self.recognizer_config.max_tokens,
                system=SYSTEM_PROMPT,
                messages=[{"role": "user", "content": content}],
                output_config={"effort": self.recognizer_config.effort,
                               "format": {"type": "json_schema", "schema": schema}},
                betas=["server-side-fallback-2026-07-01"],
                fallbacks="default",
            )
        except anthropic.RateLimitError:
            log.warning("recognizer rate limited")
            return {}, 0.0, "SKU recognition skipped for some facings: rate limited."
        except (anthropic.APIConnectionError, anthropic.APIStatusError) as exc:
            log.warning("recognizer failed: %s", exc)
            return {}, 0.0, "SKU recognition unavailable for some facings."
        cost = _cost(self.recognizer_config.model, response.usage)
        if response.stop_reason == "refusal":
            return {}, cost, "SKU recognition declined by the model for some facings."
        if response.stop_reason == "max_tokens":
            return {}, cost, "SKU recognition output truncated for some facings."
        text = next((block.text for block in response.content if block.type == "text"), "")
        try:
            items = json.loads(text)["crops"]
        except (json.JSONDecodeError, KeyError, TypeError):
            return {}, cost, "SKU recognition returned unreadable output for some facings."
        answers = {item["crop_index"]: item for item in items if 0 <= item.get("crop_index", -1) < len(crops)}
        return answers, cost, None


def _merge(detection: ProviderDetection, answer: dict, by_id: dict[str, CatalogEntry], own_manufacturer_id: str | None) -> ProviderDetection:
    confidence = max(0.0, min(1.0, float(answer.get("confidence", 0.0))))
    evidence = {**detection.evidence, "recognizer": {
        "product_id": answer["product_id"], "manufacturer_id": answer["manufacturer_id"],
        "stated_confidence": confidence, "visible_text": answer.get("visible_text", "")[:200],
    }}
    entry = by_id.get(answer["product_id"])
    if entry is not None:
        return replace(detection, product_id=entry.product_id, manufacturer_id=entry.manufacturer_id,
                       label="own" if entry.is_own else "competitor", confidence=confidence, evidence=evidence)
    manufacturer = answer["manufacturer_id"]
    if manufacturer != "unknown":
        is_own = manufacturer == own_manufacturer_id
        return replace(detection, manufacturer_id=manufacturer, label="own" if is_own else "competitor",
                       confidence=round(confidence * 0.9, 4), evidence=evidence)
    return replace(detection, evidence=evidence)


def _crop_jpeg(image: np.ndarray, detection: ProviderDetection, max_side: int) -> bytes:
    height, width = image.shape[:2]
    x0 = max(0, int(detection.x * width))
    y0 = max(0, int(detection.y * height))
    x1 = min(width, int((detection.x + detection.width) * width))
    y1 = min(height, int((detection.y + detection.height) * height))
    crop = image[y0:max(y1, y0 + 1), x0:max(x1, x0 + 1)]
    scale = max_side / max(crop.shape[:2])
    if scale < 1:
        crop = cv2.resize(crop, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    ok, encoded = cv2.imencode(".jpg", crop, [int(cv2.IMWRITE_JPEG_QUALITY), 85])
    if not ok:
        raise ValueError("Unable to encode crop")
    return encoded.tobytes()


def _cost(model: str, usage) -> float:  # type: ignore[no-untyped-def]
    price_in, price_out = PRICES.get(model, (0.0, 0.0))
    tokens_in = (usage.input_tokens or 0) + (getattr(usage, "cache_creation_input_tokens", 0) or 0) * 1.25 \
        + (getattr(usage, "cache_read_input_tokens", 0) or 0) * 0.1
    return (tokens_in * price_in + (usage.output_tokens or 0) * price_out) / 1_000_000


def _short_hash(text: str) -> str:
    import hashlib

    return hashlib.sha256(text.encode()).hexdigest()[:12]
