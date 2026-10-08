"""Adapter over the existing ai_service engine (OpenCV facings + official Square-logo matcher).

It can only tell "carries the Square logo" from "does not", so it answers at
manufacturer level: own (Square), unknown (uncertain logo), and competitor is NOT
claimed — a facing without the logo may be an own SKU with the logo hidden, so it is
reported as ``unknown`` with low confidence unless the logo score is very low.
"""

from __future__ import annotations

import hashlib
import tempfile
from pathlib import Path

import cv2
import numpy as np

from .base import CatalogEntry, ProviderDetection, ProviderResult


class OpenCvBaselineProvider:
    provider = "opencv-baseline"
    model_code = "shelf-facing-logo-baseline"

    def __init__(self) -> None:
        from ai_service.config import Settings
        from ai_service.engine import ShelfAnalysisEngine

        self._output = Path(tempfile.mkdtemp(prefix="shelfsight-baseline-"))
        settings = Settings(output_directory=self._output)
        self._settings = settings
        self._engine = ShelfAnalysisEngine(settings)
        weights = settings.logo_linear_path
        digest = hashlib.sha256(weights.read_bytes()).hexdigest()[:12] if weights else "none"
        self.version = f"{self._engine.product_detector.name}+{self._engine.logo_matcher.name}@{digest}"
        self.config = {
            "product_confidence": settings.product_confidence,
            "logo_confidence": settings.logo_confidence,
            "uncertain_logo_confidence": settings.uncertain_logo_confidence,
            "competitor_below_logo_score": 0.2,
        }

    def analyze(self, image: bytes, catalog: list[CatalogEntry], own_manufacturer_id: str | None) -> ProviderResult:
        response = self._engine.analyze([("capture.jpg", image)])
        photo = response.photos[0]
        detections: list[ProviderDetection] = []
        for item in photo.detections:
            logo_score = item.evidence.logo_confidence
            if item.label.value == "square":
                label, manufacturer, confidence = "own", own_manufacturer_id, item.confidence
            elif item.label.value == "uncertain":
                label, manufacturer, confidence = "unknown", None, 0.5
            elif logo_score < self.config["competitor_below_logo_score"]:
                # No trace of the logo at all: probably not Square, but this is not brand recognition.
                label, manufacturer, confidence = "competitor", None, round(0.55 - logo_score, 3)
            else:
                label, manufacturer, confidence = "unknown", None, 0.4
            detections.append(ProviderDetection(
                x=item.box.x, y=item.box.y, width=item.box.width, height=item.box.height,
                label=label, confidence=float(confidence), manufacturer_id=manufacturer,
                evidence={"logo_confidence": logo_score, "logo_template": item.evidence.logo_template,
                          "engine_label": item.label.value, "detector": item.evidence.detector},
            ))
        annotated_path = self._output / Path(photo.annotated_image).name
        annotated = annotated_path.read_bytes() if annotated_path.is_file() else None
        if annotated_path.is_file():
            annotated_path.unlink()
        warnings = list(response.warnings) + list(photo.quality.warnings)
        warnings.append("Baseline model identifies the Square logo only; SKUs and competitor brands are not recognised.")
        return ProviderResult(detections=detections, warnings=warnings, annotated_jpeg=annotated,
                              raw={"engine": response.engine, "summary": response.summary.model_dump()})


def image_quality(image: bytes) -> dict:
    """Same checks the engine uses, run at upload time so the officer gets instant feedback."""
    array = cv2.imdecode(np.frombuffer(image, dtype=np.uint8), cv2.IMREAD_COLOR)
    if array is None:
        raise ValueError("Unable to decode image")
    from ai_service.engine import _quality

    quality = _quality(array)
    return quality.model_dump()
